import AVFoundation
import Foundation
import CRubberBand

/// Pitch-shift a file through the same Rubber Band configuration the live
/// render callback uses, so settings can be compared by ear offline.
///
///     TRANSPOSIFY_PITCH_FILE=in.wav:out.wav \
///     TRANSPOSIFY_PITCH_SEMITONES=-4 \
///     TRANSPOSIFY_PITCH_FORMANT=preserve   .build/release/Transposify
///
/// `TRANSPOSIFY_PITCH_FORMANT` is `shift` (the default, formants move with the
/// pitch) or `preserve`. `TRANSPOSIFY_PITCH_FORMANT_SCALE` sets an explicit
/// formant ratio instead, where 1.0 holds the formants exactly where they were.
enum PitchFileTest {
    static func run(_ spec: String) -> Never {
        let err = FileHandle.standardError
        func emit(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            emit("usage: TRANSPOSIFY_PITCH_FILE=in.wav:out.wav"); exit(2)
        }
        let env = ProcessInfo.processInfo.environment
        let semitones = Double(env["TRANSPOSIFY_PITCH_SEMITONES"] ?? "-4") ?? -4
        let preserve = (env["TRANSPOSIFY_PITCH_FORMANT"] ?? "shift") == "preserve"
        let formantScale = Double(env["TRANSPOSIFY_PITCH_FORMANT_SCALE"] ?? "0") ?? 0

        do {
            let input = try AVAudioFile(forReading: URL(fileURLWithPath: parts[0]))
            let rate = input.processingFormat.sampleRate
            let channels = Int(input.processingFormat.channelCount)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                             channels: AVAudioChannelCount(channels)),
                  let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                frameCapacity: AVAudioFrameCount(input.length))
            else { emit("FAIL  could not read \(parts[0])"); exit(1) }
            try input.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard let planes = buffer.floatChannelData else { emit("FAIL  no samples"); exit(1) }

            // Exactly the live configuration, plus the formant option.
            var options: Int32 = 0x0000_0001 | 0x2000_0000 | 0x0200_0000
            if preserve { options |= 0x0100_0000 }
            guard let rb = rubberband_new(UInt32(rate), UInt32(channels), options,
                                          1.0, pow(2.0, semitones / 12.0))
            else { emit("FAIL  could not create the stretcher"); exit(1) }
            if formantScale > 0 { rubberband_set_formant_scale(rb, formantScale) }
            let block = 1024
            rubberband_set_max_process_size(rb, UInt32(block))

            var out = [[Float]](repeating: [], count: channels)
            for c in 0..<channels { out[c].reserveCapacity(frames) }
            let inPtrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: channels)
            let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
            let scratch = (0..<channels).map { _ in
                UnsafeMutablePointer<Float>.allocate(capacity: block)
            }
            defer {
                inPtrs.deallocate(); outPtrs.deallocate()
                scratch.forEach { $0.deallocate() }
            }
            for c in 0..<channels { outPtrs[c] = scratch[c] }

            func drain() {
                while rubberband_available(rb) > 0 {
                    let want = min(block, Int(rubberband_available(rb)))
                    let got = Int(rubberband_retrieve(rb, UnsafePointer(outPtrs), UInt32(want)))
                    for c in 0..<channels {
                        out[c].append(contentsOf: UnsafeBufferPointer(start: scratch[c], count: got))
                    }
                }
            }

            let began = Date()
            var fed = 0
            while fed < frames {
                let n = min(block, frames - fed)
                for c in 0..<channels { inPtrs[c] = UnsafePointer(planes[c] + fed) }
                rubberband_process(rb, UnsafePointer(inPtrs), UInt32(n), 0)
                fed += n
                drain()
            }
            rubberband_process(rb, UnsafePointer(inPtrs), 0, 1)
            drain()
            let elapsed = -began.timeIntervalSinceNow
            rubberband_delete(rb)

            let produced = out[0].count
            guard produced > 0 else { emit("FAIL  no output"); exit(1) }
            guard let writeBuf = AVAudioPCMBuffer(pcmFormat: format,
                                                  frameCapacity: AVAudioFrameCount(produced)),
                  let dst = writeBuf.floatChannelData
            else { emit("FAIL  could not allocate output"); exit(1) }
            writeBuf.frameLength = AVAudioFrameCount(produced)
            for c in 0..<channels {
                out[c].withUnsafeBufferPointer { dst[c].update(from: $0.baseAddress!, count: produced) }
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ]
            let output = try AVAudioFile(forWriting: URL(fileURLWithPath: parts[1]),
                                         settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try output.write(from: writeBuf)

            let mode = formantScale > 0
                ? String(format: "formant scale %.2f", formantScale)
                : (preserve ? "formants preserved" : "formants shifted")
            emit(String(format:
                "%+.0f st, %@: %d frames in %.2fs (%.0fx real time)",
                semitones, mode, produced, elapsed,
                Double(produced) / rate / max(elapsed, 1e-9)))
            exit(0)
        } catch {
            emit("FAIL  \(error)"); exit(1)
        }
    }
}
