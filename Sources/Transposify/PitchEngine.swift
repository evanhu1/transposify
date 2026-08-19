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
    func get() -> Int { value.load(ordering: .relaxed) }
}

private final class IntBox { var value: Int = .min }
private final class FloatBox { var value: Float = 1 }

/// Drains the capture `RingBuffer` through the Rubber Band Library (R3 "finer"
/// engine, real-time mode) for state-of-the-art pitch shifting without tempo
/// change, then out to the default output device. Optional karaoke vocal
/// reduction is applied to the input before pitch shifting.
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

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?

    private static let maxBlock = 8192

    private let ring: RingBuffer
    private let channels: Int
    private let sampleRate: Double

    private var rb: OpaquePointer?
    private var channelBuffers: [UnsafeMutablePointer<Float>]
    private let inputPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outputPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let readScratch: UnsafeMutablePointer<Float>

    private let karaokeGain = AtomicInt(100) // percent of center channel kept
    private let targetSemitones = AtomicInt(0)

    var semitones: Int = 0 {
        didSet { targetSemitones.set(max(-12, min(12, semitones))) }
    }
    var karaoke: Bool = false {
        didSet { karaokeGain.set(karaoke ? 25 : 100) }
    }

    private let holdFlag = AtomicInt(0)

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

    init(sampleRate: Double, channels: Int, ring: RingBuffer) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.ring = ring
        let ch = self.channels
        channelBuffers = (0..<ch).map { _ in .allocate(capacity: Self.maxBlock) }
        inputPtrs = .allocate(capacity: ch)
        outputPtrs = .allocate(capacity: ch)
        readScratch = .allocate(capacity: Self.maxBlock * ch)
        for c in 0..<ch { inputPtrs[c] = UnsafePointer(channelBuffers[c]) }
    }

    deinit {
        channelBuffers.forEach { $0.deallocate() }
        inputPtrs.deallocate()
        outputPtrs.deallocate()
        readScratch.deallocate()
    }

    func start() throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels))
        else { throw NSError(domain: "Transposify", code: -1) }

        let options = Self.optionProcessRealTime | Self.optionEngineFiner | Self.optionPitchHighQuality
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
        let karaokeGain = self.karaokeGain
        let targetSemitones = self.targetSemitones
        let appliedSemitones = IntBox()
        let holdFlag = self.holdFlag
        let holdGain = FloatBox()
        let gainStep = Float(1.0 / (0.010 * sampleRate))   // 10 ms fade

        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let frames = Int(frameCount)

            // Fully held: silence, and crucially, do not consume the ring.
            let holdTarget: Float = holdFlag.get() == 1 ? 0 : 1
            if holdTarget == 0 && holdGain.value == 0 {
                for c in 0..<min(ch, abl.count) {
                    if let dst = abl[c].mData?.assumingMemoryBound(to: Float.self) {
                        var f = 0
                        while f < frames { dst[f] = 0; f += 1 }
                    }
                }
                isSilence.pointee = true
                return noErr
            }

            let semis = targetSemitones.get()
            if semis != appliedSemitones.value {
                appliedSemitones.value = semis
                rubberband_set_pitch_scale(state, pow(2.0, Double(semis) / 12.0))
            }

            let gainPercent = karaokeGain.get()
            let doKaraoke = (gainPercent < 100 && ch == 2)
            let g = Float(gainPercent) / 100.0

            // Feed Rubber Band from the ring until it can produce a full buffer
            // (or the ring runs dry).
            var iterations = 0
            while Int(rubberband_available(state)) < frames && iterations < 32 {
                iterations += 1
                let required = Int(rubberband_get_samples_required(state))
                let want = min(max(required, 256), maxBlock)
                let got = ring.read(into: readScratch, count: want * ch) / ch
                if got == 0 { break }

                if doKaraoke {
                    let left = channelBuffers[0]
                    let right = channelBuffers[1]
                    var f = 0
                    while f < got {
                        let l = readScratch[f * 2]
                        let r = readScratch[f * 2 + 1]
                        let mid = (l + r) * 0.5
                        let side = (l - r) * 0.5
                        left[f] = g * mid + side
                        right[f] = g * mid - side
                        f += 1
                    }
                } else {
                    for c in 0..<ch {
                        let dst = channelBuffers[c]
                        var f = 0
                        while f < got { dst[f] = readScratch[f * ch + c]; f += 1 }
                    }
                }
                rubberband_process(state, UnsafePointer(inputPtrs), UInt32(got), 0)
            }

            let available = Int(rubberband_available(state))
            let toRetrieve = max(0, min(frames, available))
            for c in 0..<min(ch, abl.count) {
                outputPtrs[c] = abl[c].mData?.assumingMemoryBound(to: Float.self)
            }
            if toRetrieve > 0 {
                _ = rubberband_retrieve(state, UnsafePointer(outputPtrs), UInt32(toRetrieve))
            }
            if toRetrieve < frames {
                for c in 0..<min(ch, abl.count) {
                    if let dst = abl[c].mData?.assumingMemoryBound(to: Float.self) {
                        var f = toRetrieve
                        while f < frames { dst[f] = 0; f += 1 }
                    }
                }
                if toRetrieve == 0 { isSilence.pointee = true }
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
                    for c in 0..<min(ch, abl.count) {
                        if let dst = abl[c].mData?.assumingMemoryBound(to: Float.self) {
                            dst[f] *= g
                        }
                    }
                }
                holdGain.value = g
            }
            return noErr
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

    func stop() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        if let state = rb {
            rubberband_delete(state)
            rb = nil
        }
    }
}
