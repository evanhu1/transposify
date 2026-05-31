import Foundation
import CRubberBand

/// Headless proof that the Rubber Band integration actually shifts pitch:
/// push a 440 Hz sine through the real R3 engine at +7 semitones and measure
/// the output frequency via zero crossings. Run with TRANSPOSER_RBTEST=1.
enum RubberBandTest {
    static func run() {
        let err = FileHandle.standardError
        func emit(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

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
}
