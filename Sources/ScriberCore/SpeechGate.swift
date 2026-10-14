import Foundation

/// Decides, frame by frame, when someone is talking. The bar is set against the room's own background noise
/// rather than a fixed loudness, so a quiet voice or a quiet mic still counts as speech and a noisy room doesn't.
public struct SpeechGate {
    public enum Event: Equatable {
        case none
        case started
        /// The pause after speech was long enough; how long the voice lasted, gaps included.
        case ended(voicedMs: Int)
    }

    /// A pause this long ends a clip.
    public var pauseToEndMs = 1600
    /// Speech must be this many times louder than the background to start a clip…
    public var startRatio: Float = 3
    /// …and this many times to keep it going (lower, so a soft word mid-sentence doesn't end it).
    public var keepRatio: Float = 2
    /// Never lower than this, so digital silence doesn't make every hiss count.
    public var minimumStart: Float = 0.0025

    /// The background loudness: the quietest tenth of the last ~6 s. Gaps between words keep it at the
    /// background even while someone talks; steady noise raises it within a few seconds.
    public private(set) var noiseFloor: Float = 0.0015
    public private(set) var inSpeech = false
    public private(set) var voicedMs = 0
    public private(set) var pauseMs = 0
    private var background: [Float] = []

    public init() {}

    public var startThreshold: Float { max(noiseFloor * startRatio, minimumStart) }
    public var keepThreshold: Float { max(noiseFloor * keepRatio, minimumStart * 0.7) }

    public mutating func feed(_ energy: Float, ms: Int) -> Event {
        learn(energy)
        guard inSpeech else {
            if energy >= startThreshold {
                inSpeech = true
                voicedMs = ms
                pauseMs = 0
                return .started
            }
            return .none
        }
        if energy >= keepThreshold {
            voicedMs += pauseMs + ms
            pauseMs = 0
        } else {
            pauseMs += ms
        }
        if pauseMs >= pauseToEndMs {
            return end()
        }
        return .none
    }

    /// Ends the clip now (Send pressed mid-sentence). Nil if nobody was talking.
    public mutating func forceEnd() -> Int? {
        guard inSpeech, case .ended(let voiced) = end() else { return nil }
        return voiced
    }

    private mutating func end() -> Event {
        let voiced = voicedMs
        inSpeech = false
        voicedMs = 0
        pauseMs = 0
        return .ended(voicedMs: voiced)
    }

    private mutating func learn(_ energy: Float) {
        background.append(energy)
        if background.count > 140 { background.removeFirst(background.count - 140) }
        guard background.count >= 12 else { return }
        noiseFloor = background.sorted()[background.count / 10]
    }
}
