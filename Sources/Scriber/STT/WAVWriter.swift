import AVFoundation
import Foundation

enum WAVWriter {
    /// Writes 16-bit PCM WAV. Pads ~200ms of silence on each side — Whisper is more reliable with it.
    static func write(_ buffer: AVAudioPCMBuffer, to url: URL, padMs: Int = 200) throws {
        try data(buffer, padMs: padMs).write(to: url)
    }

    /// The same WAV in memory, for sending to the Whisper server.
    static func data(_ buffer: AVAudioPCMBuffer, padMs: Int = 200) -> Data {
        let format = buffer.format
        let rate = Int(format.sampleRate)
        let padFrames = rate * padMs / 1000
        let totalFrames = padFrames + Int(buffer.frameLength) + padFrames

        var samples = [Int16](repeating: 0, count: max(totalFrames, 1))
        if let data = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            for i in 0..<n {
                let clipped = max(-1, min(1, data[i]))
                samples[padFrames + i] = Int16(clipped * Float(Int16.max - 1))
            }
        } else if let data = buffer.int16ChannelData?[0] {
            let n = Int(buffer.frameLength)
            for i in 0..<n {
                samples[padFrames + i] = data[i]
            }
        }

        var header = Data()
        func ascii(_ s: String) { header.append(contentsOf: s.utf8) }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 2))
        }
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 4))
        }

        let dataBytes = UInt32(samples.count * 2)
        ascii("RIFF")
        u32(36 + dataBytes)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1) // PCM
        u16(1) // mono
        u32(UInt32(rate))
        u32(UInt32(rate * 2))
        u16(2)
        u16(16)
        ascii("data")
        u32(dataBytes)

        var body = Data(capacity: samples.count * 2)
        for s in samples {
            var le = s.littleEndian
            body.append(Data(bytes: &le, count: 2))
        }
        return header + body
    }
}
