import Foundation

/// Sample-rate conversion the worker can trust.
///
/// `AVAudioConverter` fed one block at a time mangles the seams for some block
/// sizes and not others — a 7,938-frame block came out broken while 6,615 and
/// 8,379 did not, and the frames it held back between calls swung from 35 to
/// 1,403 with block size. The pipeline's hop is exactly such a block, so the
/// hop could not be chosen freely. This converter has no such behaviour: every
/// input sample is consumed exactly once, in order, whatever the call size,
/// and output is continuous across calls.
///
/// Windowed-sinc interpolation, 32 taps, Kaiser window, 256 sub-sample phases
/// with linear interpolation between them. Unity gain per phase. Cutoff at the
/// lower of the two Nyquist frequencies with room for the transition band.
/// One instance per channel.
final class Resampler {
    private static let half = 16
    private static let taps = 2 * half
    private static let phases = 256

    /// Input samples advanced per output sample.
    private let step: Double
    private let table: [Float]

    /// History plus whatever input has not been consumed yet. The read
    /// position `pos` indexes into it; the first `half - 1` samples before
    /// `pos` and `half` after it are the filter's span.
    private var buf: [Float]
    private var pos: Double

    init(inRate: Double, outRate: Double) {
        step = inRate / outRate
        // Cycles per input sample. Pulled in to 0.92 of Nyquist so the
        // transition band does not alias when decimating.
        let cutoff = 0.5 * min(1.0, outRate / inRate) * 0.92
        var t = [Float](repeating: 0, count: (Self.phases + 1) * Self.taps)
        var row = [Double](repeating: 0, count: Self.taps)
        for sub in 0...Self.phases {
            let frac = Double(sub) / Double(Self.phases)
            var sum = 0.0
            for m in 0..<Self.taps {
                let tau = Double(m - Self.half + 1) - frac
                let x = 2 * cutoff * tau
                let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                row[m] = 2 * cutoff * sinc * Self.kaiser(tau / Double(Self.half), beta: 8)
                sum += row[m]
            }
            for m in 0..<Self.taps { t[sub * Self.taps + m] = Float(row[m] / sum) }
        }
        table = t
        // `half - 1` zeros of history put the first real sample at the
        // filter's centre, so the converter adds no delay of its own.
        buf = [Float](repeating: 0, count: Self.half - 1)
        pos = Double(Self.half - 1)
    }

    /// Consume `count` samples and append every output sample they complete.
    func process(_ input: UnsafePointer<Float>, count: Int, into out: inout [Float]) {
        buf.append(contentsOf: UnsafeBufferPointer(start: input, count: count))
        let taps = Self.taps
        let half = Self.half
        let phases = Double(Self.phases)
        buf.withUnsafeBufferPointer { b in
            table.withUnsafeBufferPointer { t in
                while Int(pos) + half < b.count {
                    let i = Int(pos)
                    let ph = (pos - Double(i)) * phases
                    let sub = Int(ph)
                    let w = Float(ph - Double(sub))
                    let base = i - half + 1
                    let r0 = sub * taps
                    let r1 = r0 + taps
                    var acc: Float = 0
                    var m = 0
                    while m < taps {
                        let h0 = t[r0 + m]
                        acc += b[base + m] * (h0 + (t[r1 + m] - h0) * w)
                        m += 1
                    }
                    out.append(acc)
                    pos += step
                }
            }
        }
        // Keep only what the next output still needs.
        let drop = Int(pos) - half + 1
        if drop > 0 {
            buf.removeFirst(drop)
            pos -= Double(drop)
        }
    }

    private static func kaiser(_ x: Double, beta: Double) -> Double {
        guard abs(x) < 1 else { return 0 }
        return besselI0(beta * (1 - x * x).squareRoot()) / besselI0(beta)
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let q = x * x / 4
        for k in 1..<40 {
            term *= q / Double(k * k)
            sum += term
            if term < sum * 1e-12 { break }
        }
        return sum
    }
}
