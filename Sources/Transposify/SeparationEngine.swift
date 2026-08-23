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

/// What the worker emits.
///
/// `passthrough` runs the same window and hop machinery but copies the input
/// instead of predicting, so the *timing* is identical to a separated hop and
/// switching costs nothing but a flag. `stems` sums the selected sources; an
/// empty mask is silence, which is what unchecking everything should give.
enum StemSelection: Equatable {
    case passthrough
    case stems(mask: Int)

    static func mask(_ indices: [Int]) -> Int {
        indices.reduce(0) { $0 | (1 << $1) }
    }

    var isPassthrough: Bool { self == .passthrough }
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
/// 3 s window through Core ML, and republishes an instrumental-only stream in
/// the *same* format it consumed — interleaved floats at the capture rate — so
/// `PitchEngine` reads it without knowing separation happened at all.
///
/// Two facts shape the design:
///
/// 1. HTDemucs is a 44.1 kHz model, but the process tap runs at the output
///    device's rate (48 kHz here), so the worker resamples both ways, with
///    its own `Resampler`. Measured cost of that round trip is 84 dB SNR —
///    far below the separation error.
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
    /// The window the converter baked in, when nothing better is known.
    /// `convert.py --segment` sets it; the app reads the real value from the
    /// model's input shape and remembers it, so a model with a different
    /// window drops in without a code change.
    static let defaultWindowFrames = 343_980   // 7.8 s at 44.1 kHz
    private static let windowKey = "modelWindowFrames"

    /// A model's window is not readable without loading it, so the last
    /// loaded model's window is kept for an engine built before the next
    /// load finishes.
    static var storedWindowFrames: Int? {
        let v = UserDefaults.standard.integer(forKey: windowKey)
        return v > 0 ? v : nil
    }

    /// Frames per window from a loaded model's input description.
    static func windowFrames(of model: MLModel) -> Int? {
        let shape = model.modelDescription.inputDescriptionsByName[inputFeature]?
            .multiArrayConstraint?.shape.map(\.intValue)
        guard let last = shape?.last, last > 0 else { return nil }
        UserDefaults.standard.set(last, forKey: windowKey)
        return last
    }

    /// This engine's window, fixed at init: the input array and every offset
    /// into it are sized from this.
    let windowFrames: Int
    static let inputFeature = "audio"
    static let outputFeature = "sources"
    /// Lookahead costs delay but no GPU, and its quality curve is shallow at
    /// the bottom: 0.25 s scored 20.5 dB against an offline reference, 0 s
    /// scored 19.3, and a 60 s file run could not separate 0.12 from 0.25 by
    /// more than half a dB at the tenth percentile. 0.12 s gives 130 ms of
    /// delay back for that half a dB.
    static let defaultLookaheadSeconds = 0.12

    /// Hop is the machine-dependent one. GPU duty is `inference / hop`, so a
    /// hop that is comfortable on fast hardware can exceed 100% duty on slow
    /// hardware — the worker would fall permanently behind and the audio would
    /// break up. Scale it to the measured inference instead of assuming.
    ///
    /// The multiplier targets ~40% duty, leaving headroom for the resampling,
    /// the window slide and ordinary scheduling jitter. Clamped so a very fast
    /// machine doesn't thrash on tiny blocks and a very slow one doesn't drift
    /// into absurd latency.
    static let dutyTarget = 0.40
    /// 0.15, not lower: with the 3 s model a 0.12 s hop ran clean at the
    /// median (60 ms predictions) but bursts of 100–200 ms predictions — the
    /// GPU being borrowed by something else — pushed duty past 85% and the
    /// worker behind. 0.15–0.16 absorbed the same bursts with no underrun.
    static let minHopSeconds = 0.15
    static let maxHopSeconds = 2.0

    /// Used until the model has been loaded once and timed. Corresponds to a
    /// mid-range Apple Silicon GPU; the real value is persisted after the first
    /// load and used from then on.
    static let assumedInferenceSeconds = 0.30

    // MARK: - Measured worst step

    /// The slowest whole step seen on this machine — inference plus the window
    /// slide, the resampling and whatever the scheduler charged. Persisted,
    /// because it is what the output ring has to be deep enough to cover, and
    /// the ring is sized before a single step has run.
    ///
    /// The median is not the number that matters. A step at twice the median
    /// empties a ring built for the median, and the render side then plays
    /// silence it never gets back — the delay grows by exactly that silence and
    /// stays grown. Sizing for the tail is what stops that ratchet.
    private static let worstStepKey = "measuredWorstStepSeconds"

    /// Clamped: one pathological step must not buy permanent latency.
    static let maxWorstStep = 0.60

    static var measuredWorstStep: Double? {
        let v = UserDefaults.standard.double(forKey: worstStepKey)
        return v > 0 ? min(v, maxWorstStep) : nil
    }

    /// Keep the high-water mark. Called as new maxima appear.
    static func recordWorstStep(_ seconds: Double) {
        guard SeparationModelLoader.persistMeasurements else { return }
        guard seconds > 0, seconds <= maxWorstStep else { return }
        guard seconds > (measuredWorstStep ?? 0) else { return }
        UserDefaults.standard.set(seconds, forKey: worstStepKey)
    }

    /// Let the mark fade a little each time the pipeline starts, so one bad
    /// session — a model loading under playback, a thermal dip — does not
    /// charge every later session for it. A machine that really is that slow
    /// re-establishes the number within seconds.
    static func forgetWorstStep() {
        UserDefaults.standard.removeObject(forKey: worstStepKey)
    }

    static func decayWorstStep() {
        guard SeparationModelLoader.persistMeasurements else { return }
        let v = UserDefaults.standard.double(forKey: worstStepKey)
        guard v > 0 else { return }
        UserDefaults.standard.set(v * 0.9, forKey: worstStepKey)
    }

    static func recommendedHopSeconds(inferenceSeconds: Double?) -> Double {
        let inference = inferenceSeconds ?? assumedInferenceSeconds
        return min(maxHopSeconds, max(minHopSeconds, inference / dutyTarget))
    }

    static var defaultHopSeconds: Double {
        recommendedHopSeconds(inferenceSeconds: SeparationModelLoader.measuredInference)
    }

    /// The converter emits [vocals, drums, bass, other].
    static let vocalSourceIndex = 0
    static let sourceCount = 4

    // MARK: - Streaming geometry

    let hopFrames: Int
    let lookaheadFrames: Int
    let crossfadeFrames: Int
    var pastFrames: Int { windowFrames - hopFrames - lookaheadFrames }
    private var rampFrames: Int { 2 * crossfadeFrames }
    /// Frames produced per prediction; the last `rampFrames` are carried over.
    private var emitFrames: Int { hopFrames + rampFrames }

    var hopSeconds: Double { Double(hopFrames) / Self.modelRate }

    /// One hop in capture-rate frames, the unit the staged and published
    /// counters are kept in.
    var hopCaptureFrames: Int { Int(Double(hopFrames) * captureRate / Self.modelRate) }

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

    // One resampler per channel and direction; see `Resampler` for why the
    // system converter is not used here.
    private let downL: Resampler
    private let downR: Resampler
    private let upL: Resampler
    private let upR: Resampler

    // Preallocated conversion buffers; the worker reuses them every step.
    private let readFrames: Int             // capture frames per drain pass
    private var interleaveScratch: [Float]
    private var planeScratch: [Float]
    private var outL: [Float] = []
    private var outR: [Float] = []

    private let ramp: [Float]              // raised cosine, `rampFrames` long

    private var thread: Thread?
    private let shouldRun = Flag(false)
    private let exited = DispatchSemaphore(value: 0)
    private let gate = Flag(true)
    private let selectionBox = Box(StemSelection.passthrough)
    private let finalDrainPending = Flag(false)
    private let stagedCounter = Counter()
    private let publishedCounter = Counter()
    private let recording: SessionRecorder.StepSink?

    // Worker-thread state.
    private var stagingL: [Float] = []
    private var stagingR: [Float] = []
    private var primed = false
    private var carryL: [Float]
    private var carryR: [Float]
    private var emitL: [Float]
    private var emitR: [Float]
    private var stepPredicted = false
    /// How long the last step's prediction took, so the recorder can tell
    /// model time from the window slide, the gather and the resampling.
    private var lastPredictSeconds = 0.0

    /// How close the output ring came to running dry, and how long the
    /// slowest hop took. Together these say whether a mode switch has any
    /// margin left: a switch from passthrough to separated costs one inference
    /// of ring occupancy, so `minOutputFrames` must stay comfortably above the
    /// audio that inference represents, or the render side underruns.
    private let minOutputBox = Box(Int.max)
    private let maxStepBox = Box(0.0)

    /// Smallest output-ring occupancy seen, in capture-rate frames.
    var minOutputFrames: Int { minOutputBox.get() }
    /// Longest single hop, in seconds — inference plus resampling and copying.
    var maxStepSeconds: Double { maxStepBox.get() }

    /// Called once playback has settled, so the figures describe steady state
    /// rather than the priming ramp.
    func resetMargins() {
        minOutputBox.set(Int.max)
        maxStepBox.set(0)
    }

    /// Latched when a prediction throws; the controller surfaces it and stops.
    private let failureBox = FailureBox()

    var failure: String? { failureBox.get() }

    // MARK: - Transport support

    /// Change what the worker emits. Safe to call at any time: the window
    /// already holds the history *and* lookahead every selection needs, so the
    /// next hop comes out changed and the raised-cosine crossfade joins it to
    /// the previous one. No rebuild, no re-prime, no gap.
    func setSelection(_ selection: StemSelection) { selectionBox.set(selection) }

    /// Hand over the model once it finishes loading. Until then the worker runs
    /// passthrough, so audio keeps playing and the switch to separated output
    /// happens at a hop boundary whenever the model turns up.
    ///
    /// A model whose window differs from this engine's cannot be used: every
    /// offset into the input array would be wrong. It is refused, and the
    /// controller rebuilds the pipeline around it.
    @discardableResult
    func setModel(_ model: MLModel?) -> Bool {
        if let model, let w = Self.windowFrames(of: model), w != windowFrames {
            log.error("""
                model window \(w, privacy: .public) frames does not match the engine's \
                \(self.windowFrames, privacy: .public); rebuilding
                """)
            modelBox.set(nil)
            return false
        }
        modelBox.set(model)
        return true
    }

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

    /// Capture-rate frames written to the output ring. Production stands here,
    /// so this is the earliest position a change made now can reach.
    var publishedCaptureFrames: Int { publishedCounter.get() }

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
         crossfadeSeconds: Double = 0.020,
         recording: SessionRecorder.StepSink? = nil) throws {
        self.modelBox = Box(model)
        self.captureRate = captureRate
        self.channels = max(1, min(2, channels))
        self.inputRing = inputRing
        self.recording = recording

        hopFrames = Int(hopSeconds * Self.modelRate)
        lookaheadFrames = Int(lookaheadSeconds * Self.modelRate)
        crossfadeFrames = Int(crossfadeSeconds * Self.modelRate)
        windowFrames = model.flatMap(Self.windowFrames(of:))
            ?? Self.storedWindowFrames ?? Self.defaultWindowFrames
        precondition(hopFrames + lookaheadFrames < windowFrames,
                     "hop + lookahead must leave room for past context")

        // Sized for the pause case: while the output is held nothing drains,
        // and the worker parks up to ~3 s of finished audio here (the rest
        // waits in staging, paced by `stepIfReady`). 4 s never overflows.
        outputRing = RingBuffer(capacityFloats: Int(captureRate * 4.0) * self.channels)

        inputArray = try MLMultiArray(
            shape: [1, 2, NSNumber(value: windowFrames)], dataType: .float32)
        memset(inputArray.dataPointer, 0,
               2 * windowFrames * MemoryLayout<Float>.size)
        featureProvider = try MLDictionaryFeatureProvider(
            dictionary: [Self.inputFeature: inputArray])

        downL = Resampler(inRate: captureRate, outRate: Self.modelRate)
        downR = Resampler(inRate: captureRate, outRate: Self.modelRate)
        upL = Resampler(inRate: Self.modelRate, outRate: captureRate)
        upR = Resampler(inRate: Self.modelRate, outRate: captureRate)

        // One drain pass takes at most this much; the capture ring holds
        // ~0.5 s, so this is never the limit.
        readFrames = Int(captureRate * 2.0)
        interleaveScratch = [Float](repeating: 0, count: readFrames * self.channels)
        planeScratch = [Float](repeating: 0, count: readFrames)
        outL.reserveCapacity(Int(captureRate))
        outR.reserveCapacity(Int(captureRate))

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
        // This thread feeds the render callback; it must outrank model loading.
        t.qualityOfService = .userInteractive
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
            let ringBefore = outputRing.availableToRead / channels
            let began = Date()
            let did = stepIfReady()
            if did {
                let elapsed = -began.timeIntervalSinceNow
                if elapsed > maxStepBox.get() { maxStepBox.set(elapsed) }
                recording?.write(durationMs: elapsed * 1_000,
                    predictMs: lastPredictSeconds * 1_000,
                    ringBeforeFrames: ringBefore,
                    ringAfterFrames: outputRing.availableToRead / channels,
                    stagingFrames: stagingL.count, predicted: stepPredicted,
                    stagedFrames: stagedCounter.get(), publishedFrames: publishedCounter.get())
            } else {
                usleep(10_000)                      // 10 ms; one hop is ~0.3 s
            }
            // Sampled after the step, which is where the ring is shallowest.
            // Only once playing: while held nothing drains, and while priming
            // the ring is legitimately empty.
            if gate.get(), primed {
                let occupancy = outputRing.availableToRead / channels
                if occupancy < minOutputBox.get() { minOutputBox.set(occupancy) }
            }
        }
        exited.signal()
        log.notice("separation worker stopped")
    }

    /// Move everything waiting in the capture ring through the downsampler and
    /// append it to the 44.1 kHz staging buffers.
    private func drainInput() {
        let available = inputRing.availableToRead
        guard available >= channels else { return }
        let wantFrames = min(available / channels, readFrames)
        guard wantFrames > 0 else { return }

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
        // De-interleave one channel at a time and resample it straight into
        // staging. A mono capture feeds both planes.
        for c in 0..<2 {
            let source = min(c, channels - 1)
            planeScratch.withUnsafeMutableBufferPointer { plane in
                var f = 0
                while f < frames { plane[f] = interleaveScratch[f * channels + source]; f += 1 }
                if c == 0 {
                    downL.process(plane.baseAddress!, count: frames, into: &stagingL)
                } else {
                    downR.process(plane.baseAddress!, count: frames, into: &stagingR)
                }
            }
        }
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
        let neededRoom = (hopCaptureFrames + 64) * channels
        guard outputRing.availableToWrite >= neededRoom else { return false }

        slideWindow(by: needed)
        stagingL.removeFirst(needed)
        stagingR.removeFirst(needed)
        primed = true

        // Separate when asked and able; otherwise copy the window through.
        // Both paths emit the same region of the same window, so the delay is
        // identical and a switch is inaudible apart from the crossfade.
        let selection = selectionBox.get()
        var separated: MLMultiArray?
        stepPredicted = !selection.isPassthrough && modelBox.get() != nil
        lastPredictSeconds = 0
        // One pool per step, so the prediction's output and Core ML's
        // temporaries are freed here, on this thread, before the next step —
        // not later, on top of it. Measured: a prediction that follows
        // another closely costs 30–50 ms less this way. The GPU still wants
        // idle time between predictions (sustained load lowers its clock),
        // which is why the hop cannot shrink to the prediction time.
        autoreleasepool {
            if stepPredicted {
                let began = Date()
                if let output = predict() {
                    lastPredictSeconds = -began.timeIntervalSinceNow
                    separated = output
                }
            }
            if stepPredicted && separated == nil { return }
            buildEmitRegion(from: separated, selection: selection)
            publish()
        }
        return true
    }

    /// Shift each channel plane left by `count` and append the next `count`
    /// staged frames, in place inside the MLMultiArray.
    private func slideWindow(by count: Int) {
        let W = windowFrames
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

    /// Run the model over the current window.
    ///
    /// Core ML allocates the ~8 MB output for every prediction. Handing it a
    /// buffer to reuse (`outputBackings`) looks like the obvious saving, and
    /// it was tried: on this GPU path it tripled the step, 108 ms to ~340 ms,
    /// and the pipeline underran ninety times in a minute. The allocation is
    /// the cheap part; forcing the GPU result into a CPU buffer is not.
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
    private func buildEmitRegion(from sources: MLMultiArray?, selection: StemSelection) {
        let elen = emitFrames
        let start = pastFrames - crossfadeFrames
        let n = rampFrames

        for i in 0..<elen { emitL[i] = 0; emitR[i] = 0 }

        emitL.withUnsafeMutableBufferPointer { l in
            emitR.withUnsafeMutableBufferPointer { r in
                if let sources, case .stems(let mask) = selection {
                    let strides = sources.strides.map(\.intValue)
                    // Source count comes from the model, not a constant, so a
                    // six-stem model would work without changing this code.
                    let count = sources.shape.count > 1 ? sources.shape[1].intValue : 0
                    func gather<T: BinaryFloatingPoint>(_ p: UnsafePointer<T>) {
                        for s in 0..<count where mask & (1 << s) != 0 {
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
                    let W = windowFrames
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
        outL.removeAll(keepingCapacity: true)
        outR.removeAll(keepingCapacity: true)
        emitL.withUnsafeBufferPointer { upL.process($0.baseAddress!, count: hopFrames, into: &outL) }
        emitR.withUnsafeBufferPointer { upR.process($0.baseAddress!, count: hopFrames, into: &outR) }
        // Both resamplers advance by the same step, so the counts agree; the
        // minimum is only a guard.
        let n = min(outL.count, outR.count)
        guard n > 0 else { return }
        let count = n * channels
        if interleaveScratch.count < count {
            interleaveScratch = [Float](repeating: 0, count: count)
        }
        interleaveScratch.withUnsafeMutableBufferPointer { dst in
            var f = 0
            if channels == 1 {
                while f < n { dst[f] = outL[f]; f += 1 }
            } else {
                while f < n {
                    dst[f * channels] = outL[f]
                    dst[f * channels + 1] = outR[f]
                    f += 1
                }
            }
            outputRing.write(dst.baseAddress!, count: count)
        }
        publishedCounter.add(n)
    }
}
