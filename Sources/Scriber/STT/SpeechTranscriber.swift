import AVFoundation
import Foundation

protocol SpeechTranscriber: AnyObject {
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String
    /// Rough words for a clip that's still being spoken; empty when live words aren't available.
    func transcribePartial(_ buffer: AVAudioPCMBuffer) async -> String
    /// Gets ready for speech (keeps the model loaded); `coolDown` lets it go.
    func warmUp() async
    func coolDown()
    var statusSummary: String { get }
    /// Names and terms the speaker is likely to say, so they're spelled the way the draft spells them.
    var vocabulary: [String] { get set }
}

enum STTError: LocalizedError {
    case unavailable(String)
    case denied
    case timeout
    case empty

    var errorDescription: String? {
        switch self {
        case .unavailable(let m): return m
        case .denied: return "Speech recognition permission denied."
        case .timeout: return "Speech recognition timed out."
        case .empty: return "Heard audio, but got no words."
        }
    }
}
