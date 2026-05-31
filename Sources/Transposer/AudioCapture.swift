import AppKit
import CoreAudio

enum AudioCaptureError: Error, CustomStringConvertible {
    case spotifyNotFound
    case processTranslateFailed(OSStatus)
    case tapCreateFailed(OSStatus)
    case tapUIDUnavailable
    case aggregateCreateFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    var description: String {
        switch self {
        case .spotifyNotFound: return "Spotify isn't running."
        case .processTranslateFailed(let s): return "Couldn't locate Spotify's audio process (status \(s))."
        case .tapCreateFailed(let s): return "Couldn't create the audio tap (status \(s)). Grant audio-capture permission?"
        case .tapUIDUnavailable: return "The audio tap has no UID."
        case .aggregateCreateFailed(let s): return "Couldn't create the capture device (status \(s))."
        case .ioProcFailed(let s): return "Couldn't install the audio callback (status \(s))."
        case .deviceStartFailed(let s): return "Couldn't start audio capture (status \(s))."
        }
    }
}

/// Captures Spotify's audio via a Core Audio process tap (macOS 14.4+) and
/// pushes interleaved float frames into a `RingBuffer`. The tap is created
/// "muted-when-tapped" so Spotify's untransposed audio is silenced at the
/// hardware and only our pitch-shifted copy is heard.
final class AudioCapture {
    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2
    private(set) var ring: RingBuffer!

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private let scratchFrameCapacity = 16_384
    private let interleaveScratch: UnsafeMutablePointer<Float>

    private let spotifyBundleID = "com.spotify.client"

    init() {
        // Sized for the worst case (scratchFrameCapacity frames × up to 8 ch).
        interleaveScratch = .allocate(capacity: scratchFrameCapacity * 8)
    }

    deinit {
        stop()
        interleaveScratch.deallocate()
    }

    func start() throws {
        guard let pid = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == spotifyBundleID })?
            .processIdentifier
        else { throw AudioCaptureError.spotifyNotFound }

        let processObject = try Self.processObject(forPID: pid)

        // 1. Create the process tap.
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
        desc.name = "Transposer Tap"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTap)
        guard tapStatus == noErr else { throw AudioCaptureError.tapCreateFailed(tapStatus) }
        tapID = newTap

        // 2. Read the tap's stream format and UID.
        var asbd = AudioStreamBasicDescription()
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &asbd) == noErr,
           asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
            channelCount = max(1, min(8, Int(asbd.mChannelsPerFrame)))
        }

        guard let tapUID = Self.copyTapUID(tapID) else {
            throw AudioCaptureError.tapUIDUnavailable
        }

        // ~0.5s of slack absorbs clock drift between the tap and output device.
        ring = RingBuffer(capacityFloats: Int(sampleRate * 0.5) * channelCount)

        // 3. Wrap the tap in a private aggregate device so it delivers IO.
        let aggregateUID = "com.evanhu.transposer.aggregate-\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transposer Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
            kAudioAggregateDeviceSubDeviceListKey: [Any](),
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate)
        guard aggStatus == noErr else { throw AudioCaptureError.aggregateCreateFailed(aggStatus) }
        aggregateID = newAggregate

        // 4. Install the IO callback. Capture plain values so the real-time
        //    block never touches `self` (no ARC traffic on the audio thread).
        let ring = self.ring!
        let scratch = interleaveScratch
        let scratchFrames = scratchFrameCapacity
        let channels = channelCount
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) {
            _, inInputData, _, _, _ in
            AudioCapture.copyInput(
                inInputData, ring: ring, scratch: scratch,
                scratchFrames: scratchFrames, channels: channels)
        }
        guard procStatus == noErr, let proc = newProc else {
            throw AudioCaptureError.ioProcFailed(procStatus)
        }
        ioProcID = proc

        // 5. Go.
        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else { throw AudioCaptureError.deviceStartFailed(startStatus) }
    }

    func stop() {
        if let proc = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - Real-time input handling

    /// Copies the tap's buffers into the ring as interleaved float frames,
    /// normalising interleaved / non-interleaved / mono layouts to stereo-ish
    /// interleaved with `channels` channels.
    private static func copyInput(
        _ inInputData: UnsafePointer<AudioBufferList>,
        ring: RingBuffer,
        scratch: UnsafeMutablePointer<Float>,
        scratchFrames: Int,
        channels: Int
    ) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData))
        guard abl.count > 0 else { return }

        if abl.count == 1 {
            let buffer = abl[0]
            guard let data = buffer.mData else { return }
            let ptr = data.assumingMemoryBound(to: Float.self)
            let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let bufferChannels = Int(buffer.mNumberChannels)

            if bufferChannels == 1 && channels == 2 {
                // Mono source → duplicate across the stereo pair.
                let frames = min(totalFloats, scratchFrames)
                var f = 0
                while f < frames {
                    scratch[f * 2] = ptr[f]
                    scratch[f * 2 + 1] = ptr[f]
                    f += 1
                }
                ring.write(scratch, count: frames * 2)
            } else {
                // Already interleaved at the channel count we expect.
                ring.write(ptr, count: totalFloats)
            }
        } else {
            // Non-interleaved: one buffer per channel. Interleave into scratch.
            let usableChannels = min(abl.count, channels)
            let frames = min(
                Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size, scratchFrames)
            for ch in 0..<usableChannels {
                guard let data = abl[ch].mData else { continue }
                let src = data.assumingMemoryBound(to: Float.self)
                var f = 0
                while f < frames {
                    scratch[f * channels + ch] = src[f]
                    f += 1
                }
            }
            ring.write(scratch, count: frames * channels)
        }
    }

    // MARK: - Core Audio property helpers

    private static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var pidValue = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object)
        }
        guard status == noErr, object != kAudioObjectUnknown else {
            throw AudioCaptureError.processTranslateFailed(status)
        }
        return object
    }

    private static func copyTapUID(_ tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfString) {
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value = cfString?.takeRetainedValue() else { return nil }
        return value as String
    }
}
