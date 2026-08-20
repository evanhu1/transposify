import AVFoundation
import CoreML
import Foundation

/// Minimal mutable flag shared with the worker thread. `Synchronization.Atomic`
/// is non-copyable, so it can't be a stored property next to the rest of this
/// file's state; a lock is plenty at this rate (read once per 10 ms poll).
private final class Flag: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ initial: Bool) { value = initial }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

/// Which stems the worker emits. Passthrough runs the same window and hop
/// machinery but copies the input instead of predicting, so the *timing* is
/// identical and switching costs nothing but a flag.
enum SeparationMode: Int {
    case passthrough = 0
    case vocals = 1
    case instrumental = 2
}

private final class Box<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ initial: T) { value = initial }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
}

/// Monotonic frame counter written by the worker, read from the main thread.
private final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func add(_ n: Int) { lock.lock(); value += n; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Neural vocal removal. Drains the capture ring, runs HTDemucs over a sliding
/// 7.8 s window through Core ML, and republishes an instrumental-only stream in
/// the *same* format it consumed — interleaved floats at the capture rate — so
/// `PitchEngine` reads it without knowing separation happened at all.
///
/// Two facts shape the design:
///
/// 1. HTDemucs is a 44.1 kHz model, but the process tap runs at the output
///    device's rate (48 kHz here), so the worker resamples both ways. Measured
///    cost of that round trip is ~55 dB SNR — far below the separation error.
/// 2. Emitting a hop needs `lookahead` seconds of *future* context, so output
///    trails input by `hop + lookahead + inference` — ~0.6 s at the defaults.
///    Separation cannot be done with less, and because switching modes has to
///    be seamless, every mode carries the same delay (see `SeparationMode`).
///    Measured quality is flat from 2.1 s down to 0.5 s of delay — 22-23 dB
///    against the offline ceiling either way — so the latency was never
///    buying fidelity. A smaller hop costs GPU instead, and only while
///    actually separating: passthrough runs no inference at all.
///
/// Adjacent predictions are joined with a raised-cosine crossfade, so window
/// seams are inaudible.
final class SeparationEngine {
    enum StartError: Error, CustomStringConvertible {
        case modelMissing
        case modelLoadFailed(String)
        case converterUnavailable

        var description: String {
            switch self {
            case .modelMissing:
                return "The vocal-removal model isn't installed yet."
            case .modelLoadFailed(let m):
                return "Couldn't load the vocal-removal model: \(m)"
            case .converterUnavailable:
                return "Couldn't set up sample-rate conversion."
            }
        }
    }

    // MARK: - Model geometry (must match the converted .mlmodelc)

    static let modelRate: Double = 44_100
    static let windowFrames = 343_980          // 7.8 s at 44.1 kHz
    static let inputFeature = "audio"
    static let outputFeature = "sources"
    /// Streaming defaults. Delay is hop + lookahead + inference (~0.6 s).
    static let defaultHopSeconds = 0.25
    static let defaultLookaheadSeconds = 0.25

    /// The converter emits [vocals, drums, bass, other].
    static let vocalSourceIndex = 0
    static let sourceCount = 4

    // MARK: - Streaming geometry

    let hopFrames: Int
    let lookaheadFrames: Int
    let crossfadeFrames: Int
    var pastFrames: Int { Self.windowFrames - hopFrames - lookaheadFrames }
    private var rampFrames: Int { 2 * crossfadeFrames }
    /// Frames produced per prediction; the last `rampFrames` are carried over.
    private var emitFrames: Int { hopFrames + rampFrames }

    /// Added latency in seconds, excluding inference time.
    var nominalDelay: Double { Double(hopFrames + lookaheadFrames) / Self.modelRate }

    // MARK: - Wiring

    private let inputRing: RingBuffer      // from AudioCapture, interleaved @ captureRate
    let outputRing: RingBuffer             // to PitchEngine, interleaved @ captureRate
    private let captureRate: Double
    private let channels: Int

    private let modelBox: Box<MLModel?>
    private let inputArray: MLMultiArray
    private let featureProvider: MLDictionaryFeatureProvider

    private let captureFormat: AVAudioFormat
    private let modelFormat: AVAudioFormat
    private let downConverter: AVAudioConverter
    private let upConverter: AVAudioConverter

    // Preallocated conversion buffers; the worker reuses them every step.
    private let downInBuf: AVAudioPCMBuffer
    private let downOutBuf: AVAudioPCMBuffer
    private let upInBuf: AVAudioPCMBuffer
    private let upOutBuf: AVAudioPCMBuffer
    private var interleaveScratch: [Float]

    private let ramp: [Float]              // raised cosine, `rampFrames` long

    private var thread: Thread?
    private let shouldRun = Flag(false)
    private let exited = DispatchSemaphore(value: 0)
    private let gate = Flag(true)
    private let modeBox = Box(SeparationMode.passthrough)
    private let finalDrainPending = Flag(false)
    private let stagedCounter = Counter()
    private let publishedCounter = Counter()

    // Worker-thread state.
    private var stagingL: [Float] = []
    private var stagingR: [Float] = []
    private var primed = false
    private var carryL: [Float]
    private var carryR: [Float]
    private var emitL: [Float]
    private var emitR: [Float]

    /// Latched when a prediction throws; the controller surfaces it and stops.
    private let failureBox = FailureBox()

    var failure: String? { failureBox.get() }

    // MARK: - Transport support

    /// Change what the worker emits. Safe to call at any time: the window
    /// already holds the history *and* lookahead every mode needs, so the next
    /// hop comes out in the new mode and the raised-cosine crossfade joins it
    /// to the previous one. No rebuild, no re-prime, no gap.
    func setMode(_ mode: SeparationMode) { modeBox.set(mode) }

    /// Hand over the model once it finishes loading. Until then the worker runs
    /// passthrough, so audio keeps playing and the switch to separated output
    /// happens at a hop boundary whenever the model turns up.
    func setModel(_ model: MLModel?) { modelBox.set(model) }

    var hasModel: Bool { modelBox.get() != nil }

    /// Open while Spotify is playing. Closing schedules one final staging pass
    /// so audio captured *before* the pause — still sitting in the capture ring
    /// — is kept; everything after it is discarded.
    func setInputGate(open: Bool) {
        if !open && gate.get() { finalDrainPending.set(true) }
        gate.set(open)
    }

    /// Total capture-rate frames staged so far. A track boundary "enters" the
    /// pipeline at this position.
    var stagedCaptureFrames: Int { stagedCounter.get() }

    /// Capture-rate frames actually handed to the render side: published minus
    /// what still waits in the output ring. A boundary recorded at
    /// `stagedCaptureFrames` has been *heard* once this counter passes it.
    var consumedCaptureFrames: Int {
        publishedCounter.get() - outputRing.availableToRead / channels
    }

    final class FailureBox: @unchecked Sendable {
        private var value: String?
        private let lock = NSLock()
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: String) { lock.lock(); if value == nil { value = v }; lock.unlock() }
    }

    // MARK: - Init

    /// `model` is loaded by `SeparationModelLoader` off the main thread; loading
    /// it here would stall engage for seconds.
    init(captureRate: Double,
         channels: Int,
         inputRing: RingBuffer,
         model: MLModel?,
         hopSeconds: Double = SeparationEngine.defaultHopSeconds,
         lookaheadSeconds: Double = SeparationEngine.defaultLookaheadSeconds,
         crossfadeSeconds: Double = 0.020) throws {
        self.modelBox = Box(model)
        self.captureRate = captureRate
        self.channels = max(1, min(2, channels))
        self.inputRing = inputRing

        hopFrames = Int(hopSeconds * Self.modelRate)
        lookaheadFrames = Int(lookaheadSeconds * Self.modelRate)
        crossfadeFrames = Int(crossfadeSeconds * Self.modelRate)
        precondition(hopFrames + lookaheadFrames < Self.windowFrames,
                     "hop + lookahead must leave room for past context")

        // Sized for the pause case: while the output is held nothing drains,
        // and the worker parks up to ~3 s of finished audio here (the rest
        // waits in staging, paced by `stepIfReady`). 4 s never overflows.
        outputRing = RingBuffer(capacityFloats: Int(captureRate * 4.0) * self.channels)

        inputArray = try MLMultiArray(
            shape: [1, 2, NSNumber(value: Self.windowFrames)], dataType: .float32)
        memset(inputArray.dataPointer, 0,
               2 * Self.windowFrames * MemoryLayout<Float>.size)
        featureProvider = try MLDictionaryFeatureProvider(
            dictionary: [Self.inputFeature: inputArray])

        guard let capFmt = AVAudioFormat(standardFormatWithSampleRate: captureRate,
                                         channels: AVAudioChannelCount(self.channels)),
              let mdlFmt = AVAudioFormat(standardFormatWithSampleRate: Self.modelRate,
                                         channels: 2),
              let down = AVAudioConverter(from: capFmt, to: mdlFmt),
              let up = AVAudioConverter(from: mdlFmt, to: capFmt)
        else { throw StartError.converterUnavailable }
        captureFormat = capFmt
        modelFormat = mdlFmt
        downConverter = down
        upConverter = up
        for converter in [down, up] {
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }

        // Capacities: the capture ring holds at most ~1.5 s, and one publish is
        // one hop. Both get generous headroom because they are allocated once.
        let inCap = AVAudioFrameCount(captureRate * 2.0)
        let downCap = AVAudioFrameCount(Self.modelRate * 2.0) + 1024
        let upInCap = AVAudioFrameCount(hopFrames)
        let upOutCap = AVAudioFrameCount(Double(hopFrames) * captureRate / Self.modelRate) + 1024
        guard let a = AVAudioPCMBuffer(pcmFormat: capFmt, frameCapacity: inCap),
              let b = AVAudioPCMBuffer(pcmFormat: mdlFmt, frameCapacity: downCap),
              let c = AVAudioPCMBuffer(pcmFormat: mdlFmt, frameCapacity: upInCap),
              let d = AVAudioPCMBuffer(pcmFormat: capFmt, frameCapacity: upOutCap)
        else { throw StartError.converterUnavailable }
        downInBuf = a; downOutBuf = b; upInBuf = c; upOutBuf = d
        interleaveScratch = [Float](repeating: 0, count: Int(inCap) * self.channels)

        let n = 2 * crossfadeFrames
        ramp = (0..<n).map { 0.5 - 0.5 * cos(Float.pi * Float($0) / Float(n - 1)) }
        carryL = [Float](repeating: 0, count: n)
        carryR = [Float](repeating: 0, count: n)
        emitL = [Float](repeating: 0, count: hopFrames + n)
        emitR = [Float](repeating: 0, count: hopFrames + n)
        stagingL.reserveCapacity(Int(Self.modelRate) * 4)
        stagingR.reserveCapacity(Int(Self.modelRate) * 4)
    }

    // MARK: - Lifecycle

    func start() {
        guard thread == nil else { return }
        shouldRun.set(true)
        let t = Thread { [weak self] in self?.run() }
        t.name = "com.evanhu.transposify.separation"
        t.qualityOfService = .userInitiated
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    func stop() {
        guard thread != nil else { return }
        shouldRun.set(false)
        _ = exited.wait(timeout: .now() + 2.0)
        thread = nil
    }

    // MARK: - Worker

    private func run() {
        log.notice("""
            separation worker started: hop \(self.hopFrames, privacy: .public) \
            lookahead \(self.lookaheadFrames, privacy: .public) frames @44.1k, \
            delay ~\(String(format: "%.2f", self.nominalDelay), privacy: .public)s
            """)
        while shouldRun.get() {
            drainInput()
            if !stepIfReady() { usleep(10_000) }   // 10 ms; one hop is 1 s
        }
        exited.signal()
        log.notice("separation worker stopped")
    }

    /// Move everything waiting in the capture ring through the downsampler and
    /// append it to the 44.1 kHz staging buffers.
    private func drainInput() {
        let available = inputRing.availableToRead
        guard available >= channels else { return }
        let wantFrames = min(available / channels, Int(downInBuf.frameCapacity))
        guard wantFrames > 0, let inChannels = downInBuf.floatChannelData else { return }

        let got = interleaveScratch.withUnsafeMutableBufferPointer {
            inputRing.read(into: $0.baseAddress!, count: wantFrames * channels)
        }
        let frames = got / channels
        guard frames > 0 else { return }

        // Paused: keep consuming the ring so it can't overflow, but discard.
        // The exception is the first pass after the gate closes, which stages
        // what was captured *before* the pause and is still in the ring.
        //
        // Everything after that is Spotify's own pause fade-out. It is an
        // artifact of stopping, not song content, and it overlaps audio that
        // resume will deliver again — so staging it both duplicates ~0.3 s and
        // pushes the pipeline permanently deeper on every single pause.
        if !gate.get() {
            if !finalDrainPending.get() { return }
            finalDrainPending.set(false)
        }
        stagedCounter.add(frames)
        downInBuf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            let dst = inChannels[c]
            var f = 0
            while f < frames { dst[f] = interleaveScratch[f * channels + c]; f += 1 }
        }

        downOutBuf.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = downConverter.convert(to: downOutBuf, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return self.downInBuf
        }
        guard status != .error, downOutBuf.frameLength > 0,
              let outChannels = downOutBuf.floatChannelData else {
            if let error { log.error("downsample failed: \(error, privacy: .public)") }
            return
        }

        let n = Int(downOutBuf.frameLength)
        let left = outChannels[0]
        let right = outChannels[downOutBuf.format.channelCount > 1 ? 1 : 0]
        stagingL.append(contentsOf: UnsafeBufferPointer(start: left, count: n))
        stagingR.append(contentsOf: UnsafeBufferPointer(start: right, count: n))
    }

    /// If enough new audio has arrived, slide the window, predict, and emit.
    /// Returns false when there is nothing to do yet.
    private func stepIfReady() -> Bool {
        guard failureBox.get() == nil else { return false }
        // The first prediction needs hop + lookahead of real audio; the past
        // context stays zero-filled, so the model simply sees a track beginning
        // from silence. Every later step advances by exactly one hop.
        let needed = primed ? hopFrames : hopFrames + lookaheadFrames
        guard stagingL.count >= needed else { return false }

        // Pace on output-ring room. While the render side is held (pause),
        // nothing drains; predicting anyway would overflow the ring and DROP
        // finished audio. Waiting keeps it safe in staging instead.
        let neededRoom = (Int(Double(hopFrames) * captureRate / Self.modelRate) + 64) * channels
        guard outputRing.availableToWrite >= neededRoom else { return false }

        slideWindow(by: needed)
        stagingL.removeFirst(needed)
        stagingR.removeFirst(needed)
        primed = true

        // Separate when asked and able; otherwise copy the window through.
        // Both paths emit the same region of the same window, so the delay is
        // identical and a switch is inaudible apart from the crossfade.
        let mode = modeBox.get()
        var separated: MLMultiArray?
        if mode != .passthrough, modelBox.get() != nil {
            guard let output = predict() else { return true }
            separated = output
        }
        buildEmitRegion(from: separated, mode: mode)
        publish()
        return true
    }

    /// Shift each channel plane left by `count` and append the next `count`
    /// staged frames, in place inside the MLMultiArray.
    private func slideWindow(by count: Int) {
        let W = Self.windowFrames
        let keep = W - count
        let base = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
        for (c, staged) in [stagingL, stagingR].enumerated() {
            let plane = base + c * W
            if keep > 0 {
                memmove(plane, plane + count, keep * MemoryLayout<Float>.size)
            }
            staged.withUnsafeBufferPointer { src in
                var f = 0
                while f < count { plane[keep + f] = src[f]; f += 1 }
            }
        }
    }

    private func predict() -> MLMultiArray? {
        guard let model = modelBox.get() else { return nil }
        do {
            let out = try model.prediction(from: featureProvider)
            return out.featureValue(for: Self.outputFeature)?.multiArrayValue
        } catch {
            let message = "\(error)"
            log.error("separation prediction failed: \(message, privacy: .public)")
            failureBox.set(message)
            return nil
        }
    }

    /// Sum the non-vocal stems over the emit region, apply the crossfade
    /// envelope, and overlap-add the previous window's tail.
    private func buildEmitRegion(from sources: MLMultiArray?, mode: SeparationMode) {
        let elen = emitFrames
        let start = pastFrames - crossfadeFrames
        let n = rampFrames

        for i in 0..<elen { emitL[i] = 0; emitR[i] = 0 }

        emitL.withUnsafeMutableBufferPointer { l in
            emitR.withUnsafeMutableBufferPointer { r in
                if let sources {
                    let strides = sources.strides.map(\.intValue)
                    let soloVocals = (mode == .vocals)
                    func gather<T: BinaryFloatingPoint>(_ p: UnsafePointer<T>) {
                        for s in 0..<Self.sourceCount
                        where soloVocals ? (s == Self.vocalSourceIndex)
                                         : (s != Self.vocalSourceIndex) {
                            let lBase = s * strides[1]
                            let rBase = s * strides[1] + strides[2]
                            var f = 0
                            while f < elen {
                                let i = (start + f) * strides[3]
                                l[f] += Float(p[lBase + i])
                                r[f] += Float(p[rBase + i])
                                f += 1
                            }
                        }
                    }
                    switch sources.dataType {
                    case .float32: gather(sources.dataPointer.assumingMemoryBound(to: Float.self))
                    case .float16: gather(sources.dataPointer.assumingMemoryBound(to: Float16.self))
                    default:
                        log.error("unexpected model output dtype \(sources.dataType.rawValue)")
                        failureBox.set("Unexpected model output type.")
                        return
                    }
                } else {
                    // Passthrough: the same region of the same window, copied
                    // straight from the input. Identical timing to a predicted
                    // hop, which is what makes the switch seamless.
                    let W = Self.windowFrames
                    let base = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
                    var f = 0
                    while f < elen {
                        l[f] = base[start + f]
                        r[f] = base[W + start + f]
                        f += 1
                    }
                }

                // Fade in over the first `n`, fade out over the last `n`.
                for f in 0..<n {
                    let g = ramp[f], h = ramp[n - 1 - f]
                    l[f] *= g;             r[f] *= g
                    l[elen - n + f] *= h;  r[elen - n + f] *= h
                }

                // Add the previous tail, then stash this window's.
                carryL.withUnsafeMutableBufferPointer { cl in
                    carryR.withUnsafeMutableBufferPointer { cr in
                        for f in 0..<n { l[f] += cl[f]; r[f] += cr[f] }
                        for f in 0..<n {
                            cl[f] = l[hopFrames + f]
                            cr[f] = r[hopFrames + f]
                        }
                    }
                }
            }
        }
    }

    /// Resample one hop back to the capture rate and write it to the output ring.
    private func publish() {
        guard let inChannels = upInBuf.floatChannelData else { return }
        upInBuf.frameLength = AVAudioFrameCount(hopFrames)
        emitL.withUnsafeBufferPointer { l in
            inChannels[0].update(from: l.baseAddress!, count: hopFrames)
        }
        if upInBuf.format.channelCount > 1 {
            emitR.withUnsafeBufferPointer { r in
                inChannels[1].update(from: r.baseAddress!, count: hopFrames)
            }
        }

        upOutBuf.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = upConverter.convert(to: upOutBuf, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return self.upInBuf
        }
        guard status != .error, upOutBuf.frameLength > 0,
              let outChannels = upOutBuf.floatChannelData else {
            if let error { log.error("upsample failed: \(error, privacy: .public)") }
            return
        }

        let n = Int(upOutBuf.frameLength)
        let count = n * channels
        if interleaveScratch.count < count {
            interleaveScratch = [Float](repeating: 0, count: count)
        }
        interleaveScratch.withUnsafeMutableBufferPointer { dst in
            for c in 0..<channels {
                let src = outChannels[min(c, Int(upOutBuf.format.channelCount) - 1)]
                var f = 0
                while f < n { dst[f * channels + c] = src[f]; f += 1 }
            }
            outputRing.write(dst.baseAddress!, count: count)
        }
        publishedCounter.add(n)
    }
}
