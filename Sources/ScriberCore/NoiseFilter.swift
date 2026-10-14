import Foundation

/// Telling taps, clicks and room noise from speech once a clip is over. Whisper turns noise into its stock
/// subtitle lines ("Thank you.", "The End"), so noise has to be caught by how loud the clip was.
/// From 39 logged clips with the room at ~0.0004: noise came in at rms 0.0010–0.0034, speech at 0.0052 and up.
public enum NoiseFilter {
    /// How loud a finished clip was, and how loud the room was around it.
    public struct Loudness: Equatable, Sendable {
        public var rms: Float
        public var background: Float
        public init(rms: Float, background: Float) {
            self.rms = rms
            self.background = background
        }
    }

    /// Too quiet to be someone talking, so it isn't sent to Whisper at all. The background ratio keeps a
    /// quiet microphone in a quiet room working.
    public static func isTooQuiet(_ clip: Loudness) -> Bool {
        clip.rms < 0.003 && clip.rms < clip.background * 6
    }

    /// A stock line only stands when the clip was clearly loud speech; otherwise it's what Whisper made of noise.
    public static func isPhantom(_ text: String, _ clip: Loudness) -> Bool {
        isStockPhrase(text) && (clip.rms < 0.006 || clip.rms < clip.background * 10)
    }

    /// Whisper's lines for audio without words (it learned them from subtitled video).
    public static func isStockPhrase(_ text: String) -> Bool {
        let t = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        return t.isEmpty || stockPhrases.contains(t)
    }

    static let stockPhrases: Set<String> = [
        "thank you", "thanks", "thank you very much", "thank you so much", "thank you for watching",
        "thanks for watching", "thank you for listening", "you", "bye", "bye-bye", "bye bye", "okay", "so",
        "the end", "i'm going to go to the next video", "see you in the next video", "please subscribe",
        "subtitles by the amara.org community", "blank_audio", "music", "silence",
    ]
}
