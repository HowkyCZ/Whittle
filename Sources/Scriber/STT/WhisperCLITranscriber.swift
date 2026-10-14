import AVFoundation
import Foundation
import ScriberCore

/// Local Whisper via whisper.cpp (Metal). Same transformer family as the speech models in AI coding apps.
@MainActor
final class WhisperCLITranscriber: SpeechTranscriber {
    private let modelStore: WhisperModelStore
    private let binaryURL: URL?
    private let server = WhisperServer()
    var vocabulary: [String] = []

    func warmUp() async {
        guard let model = modelStore.availableModelURL else { return }
        _ = await server.start(model: model)
    }

    func coolDown() {
        server.stop()
    }

    /// Editing words it otherwise hears as "backgrounds" or "program".
    private var hint: String {
        (["paragraph", "sentence", "sign-off"] + vocabulary.prefix(20)).joined(separator: ", ")
    }

    func transcribePartial(_ buffer: AVAudioPCMBuffer) async -> String {
        guard server.isReady,
              let raw = try? await server.transcribe(wav: WAVWriter.data(buffer), prompt: hint + ".") else { return "" }
        let cleaned = Self.clean(raw)
        return Self.isLikelyHallucination(cleaned, seconds: 0) || Self.echoesHint(cleaned, hint: hint) ? "" : cleaned
    }

    init(modelStore: WhisperModelStore) {
        self.modelStore = modelStore
        self.binaryURL = Self.findBinary()
    }

    var statusSummary: String {
        let bin = binaryURL?.path ?? "whisper-cli missing"
        let model = modelStore.modelDisplayName
        switch modelStore.state {
        case .downloading(let name):
            return "Whisper · downloading \(name)"
        case .failed(let m):
            return "Whisper · \(m)"
        default:
            return "Whisper · \(model) · \(bin)"
        }
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        guard let binary = binaryURL else {
            throw STTError.unavailable("whisper-cli not found. Install with: brew install whisper-cpp")
        }
        guard let model = modelStore.availableModelURL else {
            throw STTError.unavailable("Whisper model not ready yet.")
        }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let hint = self.hint

        if server.isReady {
            do {
                let wav = WAVWriter.data(buffer)
                let cleaned = Self.clean(try await server.transcribe(wav: wav, prompt: hint + "."))
                if cleaned.isEmpty || Self.isLikelyHallucination(cleaned, seconds: seconds) || Self.echoesHint(cleaned, hint: hint) {
                    TimingLog.write("Whisper server gave no words")
                    Self.keepMissedClip(wav)
                    throw STTError.empty
                }
                return cleaned
            } catch STTError.empty {
                throw STTError.empty
            } catch {
                TimingLog.write("Whisper server failed (\(error.localizedDescription)) — using the CLI")
            }
        }

        let tmp = FileManager.default.temporaryDirectory
        let wav = tmp.appendingPathComponent("scriber-\(UUID().uuidString).wav")
        let outBase = tmp.appendingPathComponent("scriber-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: outBase.appendingPathExtension("txt"))
        }

        try WAVWriter.write(buffer, to: wav)

        let vad = modelStore.availableVADModelURL

        func attempt(withVAD: Bool) async throws -> String {
            var args = [
                "-m", model.path,
                "-f", wav.path,
                "-l", "en",
                "-nt",
                "-np",
                "-sns",
                "-otxt",
                "-of", outBase.path
            ]
            if withVAD, let vad { args += ["--vad", "-vm", vad.path] }
            args += ["--prompt", hint + "."]
            do {
                return Self.clean(try await runCLI(binary: binary, arguments: args, outBase: outBase))
            } catch STTError.empty {
                return ""
            }
        }

        var cleaned = try await attempt(withVAD: vad != nil)
        // Whisper's own voice detector sometimes finds nothing in real speech; a longer clip gets a second try without it.
        if cleaned.isEmpty, vad != nil, seconds >= 2.5 {
            cleaned = try await attempt(withVAD: false)
            if Self.isLikelyHallucination(cleaned, seconds: 0) { cleaned = "" }
            TimingLog.write("Whisper retry without VAD → \"\(cleaned)\"")
        }
        if cleaned.isEmpty || Self.isLikelyHallucination(cleaned, seconds: seconds) || Self.echoesHint(cleaned, hint: hint) {
            Self.keepMissedClip(wav)
            throw STTError.empty
        }
        return cleaned
    }

    static func keepMissedClip(_ wav: Data) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scriber-missed-\(UUID().uuidString).wav")
        guard (try? wav.write(to: tmp)) != nil else { return }
        keepMissedClip(tmp)
        try? FileManager.default.removeItem(at: tmp)
    }

    /// The last few clips that gave no words, so they can be listened to.
    static func keepMissedClip(_ wav: URL) {
        let folder = TimingLog.directory.appendingPathComponent("missed-clips", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(at: wav, to: folder.appendingPathComponent("missed-\(stamp).wav"))
        let clips = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in clips.dropLast(8) { try? fm.removeItem(at: old) }
    }

    /// On near-silence Whisper can return its prompt instead of speech.
    static func echoesHint(_ text: String, hint: String) -> Bool {
        guard !hint.isEmpty else { return false }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let said = words(text)
        return !said.isEmpty && said.isSubset(of: words(hint))
    }

    /// Whisper's known outputs for short non-speech clips (it was trained on subtitled video).
    /// Longer clips are judged by how loud they were (`NoiseFilter.isPhantom`), once the words are back.
    static func isLikelyHallucination(_ text: String, seconds: Double) -> Bool {
        seconds < 3 && NoiseFilter.isStockPhrase(text)
    }

    private func runCLI(binary: URL, arguments: [String], outBase: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = arguments
                process.environment = [
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                    "HOME": NSHomeDirectory()
                ]
                let err = Pipe()
                let out = Pipe()
                process.standardError = err
                process.standardOutput = out
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let txtURL = outBase.appendingPathExtension("txt")
                if process.terminationStatus == 0,
                   let fileText = try? String(contentsOf: txtURL, encoding: .utf8),
                   !fileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(returning: fileText)
                    return
                }

                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    continuation.resume(throwing: STTError.unavailable(
                        "whisper-cli failed (\(process.terminationStatus)): \(stderr.suffix(400))"
                    ))
                    return
                }
                if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Anything Whisper complained about, to tell a Whisper problem from audio with no speech in it.
                    let notes = stderr.split(separator: "\n").filter { !$0.hasPrefix("read_audio_data") && !$0.hasPrefix("output_txt") }
                    if !notes.isEmpty { TimingLog.write("Whisper gave no text · " + notes.suffix(3).joined(separator: " | ").prefix(300)) }
                    continuation.resume(throwing: STTError.empty)
                    return
                }
                continuation.resume(returning: stdout)
            }
        }
    }

    static func clean(_ raw: String) -> String {
        var lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        lines = lines.filter { line in
            if line.hasPrefix("whisper_") { return false }
            if line.hasPrefix("system_info") { return false }
            if line.hasPrefix("main:") { return false }
            if line.hasPrefix("ggml_") { return false }
            return true
        }
        var text = lines.joined(separator: " ")
        text = text.replacingOccurrences(of: #"\[.*?\]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(.*?\)"#, with: "", options: .regularExpression)
        return text
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func findBinary() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/opt/whisper.cpp/bin/whisper-cli"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
