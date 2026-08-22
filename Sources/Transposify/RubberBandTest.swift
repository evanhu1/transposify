import Foundation
import CRubberBand

/// Headless proof that the Rubber Band integration actually shifts pitch:
/// push a 440 Hz sine through the real R3 engine at +7 semitones and measure
/// the output frequency via zero crossings. Run with TRANSPOSIFY_RBTEST=1.
enum RubberBandTest {
    static func run() {
        let err = FileHandle.standardError
        func emit(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        reportLatency(emit)
        reportTimeRatio(emit)

        let sr = 48_000
        let semitones = 7.0
        let scale = pow(2.0, semitones / 12.0)
        let inputHz = 440.0
        let expectedHz = inputHz * scale

        let options: Int32 = 0x0000_0001 | 0x2000_0000 // RealTime | EngineFiner (R3)
        guard let rb = rubberband_new(UInt32(sr), 1, options, 1.0, scale) else {
            emit("RBTEST: FAIL — could not create stretcher"); exit(1)
        }
        let block = 1024
        rubberband_set_max_process_size(rb, UInt32(block))

        let inBuf = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let inPtrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 1)
        let outBuf = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1)
        defer { inBuf.deallocate(); inPtrs.deallocate(); outBuf.deallocate(); outPtrs.deallocate() }
        inPtrs[0] = UnsafePointer(inBuf)
        outPtrs[0] = outBuf

        var output = [Float]()
        func drain() {
            while rubberband_available(rb) > 0 {
                let want = min(block, Int(rubberband_available(rb)))
                let n = Int(rubberband_retrieve(rb, UnsafePointer(outPtrs), UInt32(want)))
                for i in 0..<n { output.append(outBuf[i]) }
            }
        }

        var phase = 0.0
        let dphase = 2.0 * Double.pi * inputHz / Double(sr)
        let totalIn = sr * 2
        var fed = 0
        while fed < totalIn {
            let n = min(block, totalIn - fed)
            for i in 0..<n { inBuf[i] = Float(sin(phase)); phase += dphase }
            fed += n
            rubberband_process(rb, UnsafePointer(inPtrs), UInt32(n), 0)
            drain()
        }
        rubberband_process(rb, UnsafePointer(inPtrs), 0, 1) // final flush
        drain()
        rubberband_delete(rb)

        guard output.count > sr else {
            emit("RBTEST: FAIL — only \(output.count) output samples"); exit(1)
        }
        // Measure over a stable window, skipping startup latency/transient.
        let lo = sr / 2
        let hi = min(output.count, sr * 3 / 2)
        var crossings = 0
        var prev = output[lo]
        for i in (lo + 1)..<hi {
            let cur = output[i]
            if prev <= 0 && cur > 0 { crossings += 1 }
            prev = cur
        }
        let measured = Double(crossings) / (Double(hi - lo) / Double(sr))
        let relErr = abs(measured - expectedHz) / expectedHz
        let pass = relErr < 0.03
        emit(String(format: "RBTEST: 440Hz +7st -> expected %.1fHz, measured %.1fHz (err %.2f%%, %d samples) -> %@",
                    expectedHz, measured, relErr * 100, output.count, pass ? "PASS" : "FAIL"))
        exit(pass ? 0 : 1)
    }

    /// The depth governor drives `rubberband_set_time_ratio` on a live stream,
    /// so prove the R3 engine honours a ratio change in real-time mode: feed a
    /// fixed number of samples and check the output is shorter by the ratio.
    private static func reportTimeRatio(_ emit: (String) -> Void) {
        let sr = 48_000
        let realTime: Int32 = 0x0000_0001
        let finer: Int32 = 0x2000_0000
        let block = 1024
        for ratio in [1.0, 0.985, 0.97] {
            guard let rb = rubberband_new(UInt32(sr), 1, realTime | finer, 1.0, 1.0)
            else { continue }
            rubberband_set_max_process_size(rb, UInt32(block))
            // Set it after creation, the way the render callback does.
            rubberband_set_time_ratio(rb, ratio)
            let inBuf = UnsafeMutablePointer<Float>.allocate(capacity: block)
            let inPtrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 1)
            let outBuf = UnsafeMutablePointer<Float>.allocate(capacity: block)
            let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1)
            inPtrs[0] = UnsafePointer(inBuf); outPtrs[0] = outBuf
            var phase = 0.0
            let dphase = 2.0 * Double.pi * 440.0 / Double(sr)
            var produced = 0, fed = 0
            let total = sr * 4
            while fed < total {
                let n = min(block, total - fed)
                for i in 0..<n { inBuf[i] = Float(sin(phase)); phase += dphase }
                fed += n
                rubberband_process(rb, UnsafePointer(inPtrs), UInt32(n), 0)
                while rubberband_available(rb) > 0 {
                    let want = min(block, Int(rubberband_available(rb)))
                    produced += Int(rubberband_retrieve(rb, UnsafePointer(outPtrs), UInt32(want)))
                }
            }
            rubberband_delete(rb)
            inBuf.deallocate(); inPtrs.deallocate(); outBuf.deallocate(); outPtrs.deallocate()
            let got = Double(produced) / Double(total)
            emit(String(format: "RBRATIO: asked %.3f -> produced %.4f of input (%d of %d samples)",
                        ratio, got, produced, total))
        }
    }

    /// What the pitch shifter itself adds to the delay, per engine and shift.
    /// It sits at the very end of the pipeline, so whatever it reports here is
    /// added to every mode — including a shift of zero, where it buys nothing.
    private static func reportLatency(_ emit: (String) -> Void) {
        let sr: UInt32 = 48_000
        let realTime: Int32 = 0x0000_0001
        let finer: Int32 = 0x2000_0000        // R3
        let hq: Int32 = 0x0200_0000
        for (name, engine) in [("R3 finer", finer), ("R2 faster", Int32(0))] {
            for semitones in [0, 4, 12] {
                let scale = pow(2.0, Double(semitones) / 12.0)
                guard let rb = rubberband_new(sr, 2, realTime | engine | hq, 1.0, scale)
                else { continue }
                let latency = rubberband_get_latency(rb)
                let startDelay = rubberband_get_start_delay(rb)
                rubberband_delete(rb)
                let ms = Double(latency) / Double(sr) * 1000
                emit("RBLATENCY: \(name)  \(semitones >= 0 ? "+" : "")\(semitones) st"
                     + " -> latency \(latency) smp (\(String(format: "%.1f", ms)) ms),"
                     + " start delay \(startDelay) smp")
            }
        }
    }
}
