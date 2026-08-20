import AVFoundation
import Foundation

/// Headless check of `SeparationEngine`: pushes a file through the real engine
/// — same ring buffers, resamplers, window geometry and Core ML path the live
/// pipeline uses — and writes the instrumental out. Lets the DSP be verified
/// against the Python reference without Spotify, a tap, or an output device.
///
///     TRANSPOSIFY_MODEL=/path/HTDemucs.mlmodelc \
///     TRANSPOSIFY_SEPARATE_FILE=in.wav:out.wav .build/debug/Transposify
enum SeparationFileTest {
    static func run(_ spec: String) -> Never {
        let err = FileHandle.standardError
        func emit(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            emit("usage: TRANSPOSIFY_SEPARATE_FILE=in.wav:out.wav")
            exit(2)
        }
        guard SeparationModel.locate() != nil else {
            emit("no model found. \(SeparationModel.installHint)")
            exit(2)
        }
        // Load synchronously here; this is a batch tool with no UI to block.
        let loader = SeparationModelLoader()
        let ready = DispatchSemaphore(value: 0)
        loader.onChange = { if loader.model != nil || loader.error != nil { ready.signal() } }
        DispatchQueue.main.async { loader.prepare() }
        while ready.wait(timeout: .now() + 0.01) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard let model = loader.model else {
            emit("FAIL  \(loader.error ?? "model did not load")")
            exit(1)
        }

        // Simulate the tap: whatever the file is, present it at the capture rate.
        let captureRate = Double(
            ProcessInfo.processInfo.environment["TRANSPOSIFY_CAPTURE_RATE"] ?? "48000") ?? 48000
        let channels = 2

        do {
            let input = try loadInterleaved(path: parts[0], rate: captureRate, channels: channels)
            emit("input: \(input.count / channels) frames @ \(captureRate) Hz")

            let ring = RingBuffer(capacityFloats: Int(captureRate * 1.5) * channels)
            let started = Date()
            let env = ProcessInfo.processInfo.environment
            let hop = Double(env["TRANSPOSIFY_HOP"] ?? "")
                ?? SeparationEngine.defaultHopSeconds
            let look = Double(env["TRANSPOSIFY_LOOKAHEAD"] ?? "")
                ?? SeparationEngine.defaultLookaheadSeconds
            let engine = try SeparationEngine(
                captureRate: captureRate, channels: channels, inputRing: ring,
                model: model, hopSeconds: hop, lookaheadSeconds: look)
            emit(String(format: "model loaded in %.1fs, nominal delay %.2fs",
                        -started.timeIntervalSinceNow, engine.nominalDelay))
            // TRANSPOSIFY_ISOLATE_VOCALS=1 emits the vocal stem instead.
            let requested = ProcessInfo.processInfo.environment["TRANSPOSIFY_ISOLATE"] ?? "instrumental"
            let stems = loader.stemCount ?? 4
            let selection: StemSelection
            switch requested {
            case "off": selection = .passthrough
            case "vocals": selection = .stems(mask: 1 << Stem.vocalsIndex)
            default:
                selection = .stems(mask: StemSelection.mask(
                    (0..<stems).filter { $0 != Stem.vocalsIndex }))
            }
            engine.setSelection(selection)
            emit("mode: \(requested) over \(stems) stems")
            engine.start()

            var produced: [Float] = []
            produced.reserveCapacity(input.count)
            var fed = 0
            var idleTicks = 0
            var drain = [Float](repeating: 0, count: 1 << 16)

            // TRANSPOSIFY_SWITCH_AT=<seconds> flips mode mid-stream, so the
            // cutover can be checked for gaps, repeats or drift.
            let switchAt = Double(
                ProcessInfo.processInfo.environment["TRANSPOSIFY_SWITCH_AT"] ?? "") ?? -1
            var switched = switchAt < 0
            let runStart = Date()
            while true {
                if fed < input.count {
                    let room = ring.availableToWrite
                    if room > 0 {
                        let n = min(room, input.count - fed)
                        input.withUnsafeBufferPointer {
                            ring.write($0.baseAddress! + fed, count: n)
                        }
                        fed += n
                    }
                }
                let got = drain.withUnsafeMutableBufferPointer {
                    engine.outputRing.read(into: $0.baseAddress!, count: $0.count)
                }
                if got > 0 {
                    produced.append(contentsOf: drain[0..<got])
                    idleTicks = 0
                    if !switched,
                       Double(produced.count / channels) / captureRate >= switchAt {
                        switched = true
                        engine.setSelection(.stems(mask: StemSelection.mask(
                            (0..<(loader.stemCount ?? 4)).filter { $0 != Stem.vocalsIndex })))
                        emit(String(format: "  switched to instrumental at %.2fs",
                                    Double(produced.count / channels) / captureRate))
                    }
                } else {
                    idleTicks += 1
                }
                // Done once the input is exhausted and the worker has gone
                // quiet. The threshold has to clear a single slow inference:
                // a freshly compiled Core ML model specialises on its first
                // few predictions and can take seconds, and a tighter bound
                // silently truncates the output instead of failing.
                if fed >= input.count && idleTicks > 5_000 { break }   // 10 s
                if -runStart.timeIntervalSinceNow > 600 {
                    emit("timed out"); break
                }
                usleep(2_000)
            }
            engine.stop()

            if let failure = engine.failure {
                emit("FAIL  engine reported: \(failure)")
                exit(1)
            }

            let elapsed = -runStart.timeIntervalSinceNow
            let inSeconds = Double(input.count / channels) / captureRate
            let outSeconds = Double(produced.count / channels) / captureRate
            emit(String(format: "output: %.2fs from %.2fs input (%.2fs lost to priming)",
                        outSeconds, inSeconds, inSeconds - outSeconds))
            emit(String(format: "processed in %.1fs = %.1fx realtime", elapsed,
                        inSeconds / elapsed))

            try writeInterleaved(produced, path: parts[1], rate: captureRate, channels: channels)
            emit("wrote \(parts[1])")
            exit(0)
        } catch {
            emit("FAIL  \(error)")
            exit(1)
        }
    }

    /// Load any audio file and hand it back as interleaved floats at `rate`.
    private static func loadInterleaved(path: String, rate: Double, channels: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let sourceFormat = file.processingFormat
        guard let sourceBuf = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "SeparationFileTest", code: -1)
        }
        try file.read(into: sourceBuf)

        guard let target = AVAudioFormat(standardFormatWithSampleRate: rate,
                                         channels: AVAudioChannelCount(channels)),
              let converter = AVAudioConverter(from: sourceFormat, to: target)
        else { throw NSError(domain: "SeparationFileTest", code: -2) }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let capacity = AVAudioFrameCount(Double(sourceBuf.frameLength)
            * rate / sourceFormat.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
              let planes = outBuf.floatChannelData
        else { throw NSError(domain: "SeparationFileTest", code: -3) }

        var supplied = false
        var error: NSError?
        _ = converter.convert(to: outBuf, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return sourceBuf
        }
        if let error { throw error }

        let n = Int(outBuf.frameLength)
        var interleaved = [Float](repeating: 0, count: n * channels)
        for c in 0..<channels {
            let src = planes[min(c, Int(target.channelCount) - 1)]
            for f in 0..<n { interleaved[f * channels + c] = src[f] }
        }
        return interleaved
    }

    private static func writeInterleaved(_ samples: [Float], path: String,
                                         rate: Double, channels: Int) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                         channels: AVAudioChannelCount(channels))
        else { throw NSError(domain: "SeparationFileTest", code: -4) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings)
        let frames = samples.count / channels
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(frames)),
              let planes = buf.floatChannelData
        else { throw NSError(domain: "SeparationFileTest", code: -5) }
        buf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            let dst = planes[c]
            for f in 0..<frames { dst[f] = samples[f * channels + c] }
        }
        try file.write(from: buf)
    }
}
