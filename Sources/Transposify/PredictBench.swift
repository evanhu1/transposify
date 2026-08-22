import AVFoundation
import CoreML
import Foundation

/// Why does a streaming prediction take 150–200 ms when the warm-up measures
/// the same model at 108 ms? This isolates the candidates one at a time:
/// what is in the window, how busy the GPU is kept, and which thread asks.
///
///     TRANSPOSIFY_PREDICT_BENCH=song.wav .build/release/Transposify
enum PredictBench {
    static func run(_ path: String) -> Never {
        let err = FileHandle.standardError
        func emit(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        let loader = SeparationModelLoader()
        SeparationModelLoader.persistMeasurements = false
        let ready = DispatchSemaphore(value: 0)
        loader.onChange = { if loader.model != nil || loader.error != nil { ready.signal() } }
        DispatchQueue.main.async { loader.prepare() }
        while ready.wait(timeout: .now() + 0.01) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard let model = loader.model else { emit("FAIL \(loader.error ?? "no model")"); exit(1) }

        let frames = SeparationEngine.windowFrames
        guard let silence = try? MLMultiArray(shape: [1, 2, NSNumber(value: frames)], dataType: .float32),
              let music = try? MLMultiArray(shape: [1, 2, NSNumber(value: frames)], dataType: .float32)
        else { exit(1) }
        memset(silence.dataPointer, 0, 2 * frames * 4)
        do {
            let samples = try loadStereo44k(path: path, frames: frames)
            let p = music.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { p[i] = samples.0[i]; p[frames + i] = samples.1[i] }
        } catch {
            emit("FAIL could not load \(path): \(error)"); exit(1)
        }
        guard let silenceIn = try? MLDictionaryFeatureProvider(dictionary: [SeparationEngine.inputFeature: silence]),
              let musicIn = try? MLDictionaryFeatureProvider(dictionary: [SeparationEngine.inputFeature: music])
        else { exit(1) }

        var pooled = false
        func predict(_ input: MLFeatureProvider) -> Double {
            let t = Date()
            if pooled {
                autoreleasepool { _ = try? model.prediction(from: input) }
            } else {
                _ = try? model.prediction(from: input)
            }
            return -t.timeIntervalSinceNow * 1000
        }
        func stats(_ xs: [Double]) -> String {
            let s = xs.sorted()
            return String(format: "median %4.0f  p90 %4.0f  max %4.0f ms",
                          s[s.count / 2], s[Int(Double(s.count) * 0.9)], s.last ?? 0)
        }
        func series(_ label: String, input: MLFeatureProvider, runs: Int, gapMs: Int,
                    qos: QualityOfService?) {
            var times: [Double] = []
            let done = DispatchSemaphore(value: 0)
            let body = {
                _ = predict(input)                      // discard the first
                for _ in 0..<runs {
                    times.append(predict(input))
                    if gapMs > 0 { Thread.sleep(forTimeInterval: Double(gapMs) / 1000) }
                }
                done.signal()
            }
            if let qos {
                let t = Thread(block: body)
                t.qualityOfService = qos
                t.start()
            } else {
                DispatchQueue.global(qos: .utility).async(execute: body)
            }
            done.wait()
            emit(label.padding(toLength: 36, withPad: " ", startingAt: 0) + stats(times))
        }

        emit("PREDICTBENCH: \(frames) frames, \(loader.stemCount ?? 0) stems")
        for gap in [0, 30, 60, 90, 120, 200] {
            series("music, \(gap) ms gaps, plain", input: musicIn, runs: 12, gapMs: gap, qos: .userInteractive)
        }
        pooled = true
        for gap in [0, 30, 60, 90, 120, 200] {
            series("music, \(gap) ms gaps, autoreleasepool", input: musicIn, runs: 12, gapMs: gap, qos: .userInteractive)
        }
        exit(0)
    }

    /// First `frames` of the file as two 44.1 kHz planes.
    private static func loadStereo44k(path: String, frames: Int) throws -> ([Float], [Float]) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw NSError(domain: "PredictBench", code: -1) }
        try file.read(into: inBuf)
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: outBuf, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return inBuf
        }
        if let error { throw error }
        let n = Int(outBuf.frameLength)
        guard n > 0, let ch = outBuf.floatChannelData else { throw NSError(domain: "PredictBench", code: -2) }
        var l = [Float](repeating: 0, count: frames), r = l
        for i in 0..<min(n, frames) { l[i] = ch[0][i]; r[i] = ch[1][i] }
        return (l, r)
    }
}
