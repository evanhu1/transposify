import AVFoundation
import Foundation
import Synchronization
import CRubberBand

/// Reference wrappers so non-copyable atomics / mutable state can be captured
/// by the real-time render closure.
private final class AtomicInt: @unchecked Sendable {
    private let value: Atomic<Int>
    init(_ initial: Int) { value = Atomic<Int>(initial) }
    func set(_ newValue: Int) { value.store(newValue, ordering: .relaxed) }
    func add(_ n: Int) { value.wrappingAdd(n, ordering: .relaxed) }
    func get() -> Int { value.load(ordering: .relaxed) }
}

private final class IntBox { var value: Int = .min }
private final class FloatBox { var value: Float = 1 }

/// Drains the capture `RingBuffer` through the Rubber Band Library (R3 "finer"
/// engine, real-time mode) for state-of-the-art pitch shifting without tempo
/// change, then out to the default output device. Vocal isolation, when on,
/// happens upstream in `SeparationEngine`, which republishes the same format —
/// so this stage never knows about it.
///
/// Rubber Band runs directly in the `AVAudioSourceNode` render callback: each
/// pull, we feed it input from the ring (as much as it needs) and retrieve one
/// buffer of shifted output. Latency is higher than Apple's AUNewTimePitch, but
/// that's fine here — you sing *along to* the output, so there's no monitoring
/// loop, and R3 quality is the priority.
final class PitchEngine {
    // Rubber Band option bits (from rubberband-c.h).
    private static let optionProcessRealTime: Int32 = 0x0000_0001
    private static let optionPitchHighQuality: Int32 = 0x0200_0000
    private static let optionEngineFiner: Int32 = 0x2000_0000 // R3
    private static let optionFormantPreserved: Int32 = 0x0100_0000

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?

    private static let maxBlock = 8192

    private let ring: RingBuffer
    /// The vocal on its own, when the caller wants it shifted with its
    /// formants held while the rest of the mix is shifted normally.
    private let vocalRing: RingBuffer?
    private let channels: Int
    private let sampleRate: Double
    private let recorder: SessionRecorder?
    private let manualRendering: Bool

    private var rb: OpaquePointer?
    private var rbVocal: OpaquePointer?
    private var channelBuffers: [UnsafeMutablePointer<Float>]
    private let inputPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outputPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let readScratch: UnsafeMutablePointer<Float>
    private let vocalRead: UnsafeMutablePointer<Float>
    private var vocalIn: [UnsafeMutablePointer<Float>]
    private var vocalOut: [UnsafeMutablePointer<Float>]
    private let vocalInPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let vocalOutPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private var manualOutputBuffers: [UnsafeMutablePointer<Float>] = []
    private typealias RenderCore = (
        UnsafeMutablePointer<ObjCBool>, Int,
        UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, Int
    ) -> OSStatus
    private var renderCore: RenderCore?

    private let targetSemitones = AtomicInt(0)

    var semitones: Int = 0 {
        didSet { targetSemitones.set(max(-12, min(12, semitones))) }
    }
    private let holdFlag = AtomicInt(0)
    private let timeRatioMilli = AtomicInt(1000)
    /// Formant handling as thousandths: 0 lets the formants move with the
    /// pitch, 1000 holds them where they were, 1100 lifts them a further 10%.
    private let formantOverMilli = AtomicInt(1000)
    private let underrunCount = AtomicInt(0)

    /// Render pulls that came up short — the output ring ran dry. Any non-zero
    /// value is audible as a gap, so this is the number to watch when judging
    /// whether a transition is actually seamless.
    var underruns: Int { underrunCount.get() }

    /// Called once the pipeline has primed, so the count that follows reflects
    /// real glitches rather than the expected start-up gap.
    func resetUnderruns() { underrunCount.set(0) }

    /// Play slightly fast to give back delay the pipeline accumulated.
    ///
    /// Rubber Band's time ratio is output duration over input duration, so a
    /// ratio below 1 consumes the ring faster than it emits and the pipeline
    /// gets shallower. Pitch is untouched. Held as thousandths because the
    /// render callback reads it atomically.
    var timeRatio: Double = 1.0 {
        didSet { timeRatioMilli.set(Int((max(0.9, min(1.0, timeRatio)) * 1000).rounded())) }
    }

    /// Hold the vocal formants where they were instead of letting them move
    /// with the pitch.
    ///
    /// Shifting a voice down moves its whole spectral envelope down with it,
    /// which is what makes a singer sound like a much larger one. Rubber Band
    /// can estimate that envelope and put it back, so the note changes and the
    /// voice does not. Costs about 8% more processing and is safe to change
    /// mid-stream.
    /// nil moves the formants with the pitch. 1.0 holds them exactly where
    /// they were; above that lifts them further, which counteracts whatever
    /// chestiness the envelope estimate leaves behind.
    var formantOver: Double? = 1.0 {
        didSet {
            formantOverMilli.set(formantOver.map { Int(($0 * 1000).rounded()) } ?? 0)
        }
    }

    /// While held, the render callback outputs silence *without draining the
    /// ring*, after a 10 ms fade. Everything buffered upstream stays put, so
    /// releasing the hold resumes the exact sample where it stopped. This is
    /// what makes pause instant in the delayed (separation) pipeline: pausing
    /// the delayed stream needs no new audio, just a frozen buffer.
    var hold: Bool = false {
        didSet { holdFlag.set(hold ? 1 : 0) }
    }

    /// Fired (on main) when the audio route/format changes; controller rebuilds.
    var onConfigurationChange: (() -> Void)?

    init(sampleRate: Double, channels: Int, ring: RingBuffer,
         vocalRing: RingBuffer? = nil,
         recorder: SessionRecorder? = nil, manualRendering: Bool = false) {
        self.vocalRing = vocalRing
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.ring = ring
        self.recorder = recorder
        self.manualRendering = manualRendering
        let ch = self.channels
        channelBuffers = (0..<ch).map { _ in .allocate(capacity: Self.maxBlock) }
        inputPtrs = .allocate(capacity: ch)
        outputPtrs = .allocate(capacity: ch)
        readScratch = .allocate(capacity: Self.maxBlock * ch)
        vocalRead = .allocate(capacity: Self.maxBlock * ch)
        vocalIn = (0..<ch).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: Self.maxBlock) }
        vocalOut = (0..<ch).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: Self.maxBlock) }
        vocalInPtrs = .allocate(capacity: ch)
        vocalOutPtrs = .allocate(capacity: ch)
        for c in 0..<ch {
            vocalInPtrs[c] = UnsafePointer(vocalIn[c])
            vocalOutPtrs[c] = vocalOut[c]
        }
        for c in 0..<ch { inputPtrs[c] = UnsafePointer(channelBuffers[c]) }
        if manualRendering {
            manualOutputBuffers = (0..<ch).map { _ in .allocate(capacity: Self.maxBlock) }
        }
    }

    deinit {
        channelBuffers.forEach { $0.deallocate() }
        inputPtrs.deallocate()
        outputPtrs.deallocate()
        readScratch.deallocate()
        vocalRead.deallocate()
        vocalIn.forEach { $0.deallocate() }
        vocalOut.forEach { $0.deallocate() }
        vocalInPtrs.deallocate()
        vocalOutPtrs.deallocate()
        manualOutputBuffers.forEach { $0.deallocate() }
    }

    func start() throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels))
        else { throw NSError(domain: "Transposify", code: -1) }

        var options = Self.optionProcessRealTime | Self.optionEngineFiner | Self.optionPitchHighQuality
        if formantOver != nil { options |= Self.optionFormantPreserved }
        let initialScale = pow(2.0, Double(targetSemitones.get()) / 12.0)
        guard let state = rubberband_new(UInt32(sampleRate), UInt32(channels),
                                         options, 1.0, initialScale) else {
            throw NSError(domain: "Transposify", code: -2)
        }
        rubberband_set_max_process_size(state, UInt32(Self.maxBlock))
        rb = state

        let ring = self.ring
        let ch = self.channels
        let maxBlock = Self.maxBlock
        let readScratch = self.readScratch
        let channelBuffers = self.channelBuffers
        let inputPtrs = self.inputPtrs
        let outputPtrs = self.outputPtrs
        let targetSemitones = self.targetSemitones
        let appliedSemitones = IntBox()
        let timeRatioMilli = self.timeRatioMilli
        let appliedRatioMilli = IntBox()
        let formantOverMilli = self.formantOverMilli
        let appliedFormant = IntBox()
        let holdFlag = self.holdFlag
        let underrunCount = self.underrunCount
        let holdGain = FloatBox()
        let gainStep = Float(1.0 / (0.010 * sampleRate))   // 10 ms fade
        let recording = recorder?.outputSink

        let core: RenderCore = { isSilence, frames, destinations, destinationChannels in
            // Fully held: silence, and crucially, do not consume the ring.
            let holdTarget: Float = holdFlag.get() == 1 ? 0 : 1
            if holdTarget == 0 && holdGain.value == 0 {
                for c in 0..<min(ch, destinationChannels) {
                    if let dst = destinations[c] {
                        var f = 0
                        while f < frames { dst[f] = 0; f += 1 }
                    }
                }
                isSilence.pointee = true
                recording?.writePlanar(UnsafePointer(destinations),
                                       availableChannels: destinationChannels, frames: frames)
                return noErr
            }

            // Pitch and formants are set together: the formant scale is
            // expressed relative to the pitch scale, so a change in either
            // one has to recompute it.
            let semis = targetSemitones.get()
            let over = formantOverMilli.get()
            if semis != appliedSemitones.value || over != appliedFormant.value {
                appliedSemitones.value = semis
                appliedFormant.value = over
                let pitchScale = pow(2.0, Double(semis) / 12.0)
                rubberband_set_pitch_scale(state, pitchScale)
                if over == 0 {
                    // Back to automatic, governed by the option: formants move.
                    rubberband_set_formant_scale(state, 0)
                    rubberband_set_formant_option(state, 0)
                } else if over == 1000 {
                    // Exactly preserved. Use the option rather than an
                    // equivalent scale, so this stays the path Rubber Band
                    // documents for ordinary formant preservation.
                    rubberband_set_formant_scale(state, 0)
                    rubberband_set_formant_option(state, Self.optionFormantPreserved)
                } else {
                    rubberband_set_formant_option(state, Self.optionFormantPreserved)
                    rubberband_set_formant_scale(state, Double(over) / 1000 / pitchScale)
                }
            }

            let ratioMilli = timeRatioMilli.get()
            if ratioMilli != appliedRatioMilli.value {
                appliedRatioMilli.value = ratioMilli
                rubberband_set_time_ratio(state, Double(ratioMilli) / 1000)
            }

            // Feed Rubber Band from the ring until it can produce a full buffer
            // (or the ring runs dry).
            var iterations = 0
            while Int(rubberband_available(state)) < frames && iterations < 32 {
                iterations += 1
                let required = Int(rubberband_get_samples_required(state))
                let want = min(max(required, 256), maxBlock)
                let got = ring.read(into: readScratch, count: want * ch) / ch
                if got == 0 { break }

                for c in 0..<ch {
                    let dst = channelBuffers[c]
                    var f = 0
                    while f < got { dst[f] = readScratch[f * ch + c]; f += 1 }
                }
                rubberband_process(state, UnsafePointer(inputPtrs), UInt32(got), 0)
            }

            let available = Int(rubberband_available(state))
            let toRetrieve = max(0, min(frames, available))
            if toRetrieve > 0 {
                _ = rubberband_retrieve(state, UnsafePointer(destinations), UInt32(toRetrieve))
            }
            if toRetrieve < frames {
                for c in 0..<min(ch, destinationChannels) {
                    if let dst = destinations[c] {
                        var f = toRetrieve
                        while f < frames { dst[f] = 0; f += 1 }
                    }
                }
                if toRetrieve == 0 { isSilence.pointee = true }
                underrunCount.add(1)
                recording?.underrun(shortFrames: frames - toRetrieve,
                                    ringFrames: ring.availableToRead / ch)
            }

            // Ramp toward the hold target so pause/resume never clicks. The
            // ~10 ms consumed during the fade plays at falling gain.
            if holdGain.value != holdTarget {
                var g = holdGain.value
                for f in 0..<frames {
                    if g < holdTarget {
                        g = min(holdTarget, g + gainStep)
                    } else {
                        g = max(holdTarget, g - gainStep)
                    }
                    for c in 0..<min(ch, destinationChannels) {
                        if let dst = destinations[c] {
                            dst[f] *= g
                        }
                    }
                }
                holdGain.value = g
            }
            recording?.writePlanar(UnsafePointer(destinations),
                                   availableChannels: destinationChannels, frames: frames)
            return noErr
        }
        renderCore = core

        if manualRendering {
            for channel in 0..<channels { outputPtrs[channel] = manualOutputBuffers[channel] }
        } else {
            let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, ablPtr in
                let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
                let count = min(ch, buffers.count)
                for channel in 0..<count {
                    outputPtrs[channel] = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
                }
                return core(isSilence, Int(frameCount), outputPtrs, count)
            }
            sourceNode = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                self?.onConfigurationChange?()
            }
            engine.prepare()
            try engine.start()
        }
    }

    /// Pulls the same source-node callback used by the live output device.
    func renderOffline(frames: Int, into output: UnsafeMutablePointer<Float>) throws {
        guard manualRendering, frames <= Self.maxBlock, let renderCore else {
            throw NSError(domain: "TransposifySimulator", code: -2)
        }
        var isSilence = ObjCBool(false)
        _ = withUnsafeMutablePointer(to: &isSilence) {
            renderCore($0, frames, outputPtrs, channels)
        }
        var frame = 0
        while frame < frames {
            var channel = 0
            while channel < channels {
                output[frame * channels + channel] = manualOutputBuffers[channel][frame]
                channel += 1
            }
            frame += 1
        }
    }

    func stop() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if !manualRendering { engine.stop() }
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        if let state = rb {
            renderCore = nil
            rubberband_delete(state)
            rb = nil
        }
        if let state = rbVocal {
            rubberband_delete(state)
            rbVocal = nil
        }
    }
}
