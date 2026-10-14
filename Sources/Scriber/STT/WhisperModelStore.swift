import Foundation
import ScriberCore

/// ggml Whisper weights in Application Support. Prefers large-v3-turbo, else base.en.
@MainActor
final class WhisperModelStore: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(name: String)
        case ready(URL)
        case failed(String)
    }

    @Published var state: State = .idle

    static let modelsDirectory: URL = AppSupport.folder.appendingPathComponent("models", isDirectory: true)

    var availableModelURL: URL? {
        let turbo = Self.modelsDirectory.appendingPathComponent("ggml-large-v3-turbo.bin")
        let base = Self.modelsDirectory.appendingPathComponent("ggml-base.en.bin")
        let fm = FileManager.default
        if fm.fileExists(atPath: turbo.path), fileSize(turbo) > 100_000_000 { return turbo }
        if fm.fileExists(atPath: base.path), fileSize(base) > 50_000_000 { return base }
        return nil
    }

    /// Silero speech detector for whisper.cpp — clips with no speech come back empty instead of "Thank you."
    static let vadModelURL = modelsDirectory.appendingPathComponent("ggml-silero-v5.1.2.bin")
    private static let vadRemote = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    var availableVADModelURL: URL? {
        fileSize(Self.vadModelURL) > 100_000 ? Self.vadModelURL : nil
    }

    func ensureVADModel() async {
        guard availableVADModelURL == nil else { return }
        guard let (tmp, response) = try? await URLSession.shared.download(from: Self.vadRemote),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return }
        try? FileManager.default.removeItem(at: Self.vadModelURL)
        try? FileManager.default.moveItem(at: tmp, to: Self.vadModelURL)
    }

    var modelDisplayName: String {
        guard let url = availableModelURL else { return "none" }
        if url.lastPathComponent.contains("turbo") { return "large-v3-turbo" }
        if url.lastPathComponent.contains("base.en") { return "base.en" }
        return url.deletingPathExtension().lastPathComponent
    }

    func ensureReady() async {
        try? FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        await ensureVADModel()
        if let url = availableModelURL {
            state = .ready(url)
            return
        }

        let candidates: [(String, URL)] = [
            (
                "ggml-large-v3-turbo.bin",
                URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
            ),
            (
                "ggml-base.en.bin",
                URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!
            )
        ]

        var lastError: Error?
        for (name, remote) in candidates {
            do {
                let url = try await download(name: name, from: remote)
                state = .ready(url)
                return
            } catch {
                lastError = error
            }
        }
        state = .failed(lastError?.localizedDescription ?? "Could not download a Whisper model.")
    }

    private func download(name: String, from remote: URL) async throws -> URL {
        let dest = Self.modelsDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path), fileSize(dest) > 50_000_000 {
            return dest
        }
        state = .downloading(name: name)

        let (tmp, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "WhisperModelStore", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Download failed (\(http.statusCode)) for \(name)"
            ])
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
        guard fileSize(dest) > 50_000_000 else {
            try? FileManager.default.removeItem(at: dest)
            throw NSError(domain: "WhisperModelStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded file for \(name) looks truncated."
            ])
        }
        return dest
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
