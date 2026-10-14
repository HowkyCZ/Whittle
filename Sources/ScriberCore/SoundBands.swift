import Accelerate
import Foundation

/// How loud each part of the voice is right now, for the mic's sound lines: low (body of the voice),
/// low-mid (vowels), high-mid (consonants), high ("s" sounds). Each band is measured against its own
/// background noise, the same way `SpeechGate` is, so a quiet voice still moves the lines.
public final class SoundBands {
    public static let edges: [Double] = [90, 300, 1000, 3000, 7000]
    public static let windowSize = 512
    /// A band this many dB over its background reads as full.
    public static let rangeDb: Float = 26
    /// …and this many dB over it is where the line starts to open.
    public static let thresholdDb: Float = 4

    private let log2n = vDSP_Length(9)
    private let setup: FFTSetup
    private let window: [Float]
    private var history: [[Float]] = Array(repeating: [], count: 4)

    public init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: Self.windowSize)
        vDSP_hann_window(&window, vDSP_Length(Self.windowSize), Int32(vDSP_HANN_NORM))
        self.window = window
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Band levels 0…1 for the most recent `windowSize` samples.
    public func levels(_ samples: [Float], sampleRate: Double) -> [Double] {
        let n = Self.windowSize
        var input = [Float](repeating: 0, count: n)
        let tail = samples.suffix(n)
        input.replaceSubrange((n - tail.count)..<n, with: tail)
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                input.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }

        let binHz = sampleRate / Double(n)
        return (0..<4).map { band in
            let low = max(1, Int(Self.edges[band] / binHz))
            let high = min(n / 2 - 1, Int(Self.edges[band + 1] / binHz))
            var sum: Float = 0
            if high >= low { vDSP_sve(Array(power[low...high]), 1, &sum, vDSP_Length(high - low + 1)) }
            let db = 10 * log10(max(sum, 1e-12))
            let floor = learn(db, band: band)
            return Double(min(1, max(0, (db - floor - Self.thresholdDb) / (Self.rangeDb - Self.thresholdDb))))
        }
    }

    /// The band's background: the quietest tenth of the last ~6 s.
    private func learn(_ db: Float, band: Int) -> Float {
        history[band].append(db)
        if history[band].count > 180 { history[band].removeFirst(history[band].count - 180) }
        let sorted = history[band].sorted()
        return sorted[sorted.count / 10]
    }
}
