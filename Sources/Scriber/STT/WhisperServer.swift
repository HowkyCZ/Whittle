import Foundation
import ScriberCore

/// whisper.cpp's server with the model kept loaded, so a transcription takes ~0.5 s instead of ~1.5 s.
/// That's what makes live words possible. Runs on 127.0.0.1 only, while the panel is in use.
final class WhisperServer: @unchecked Sendable {
    static let port = 8178

    private let lock = NSLock()
    private var process: Process?
    private var ready = false
    private var starting: Task<Bool, Never>?

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(Self.port)")! }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    static func findBinary() -> URL? {
        ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server", "/opt/homebrew/opt/whisper.cpp/bin/whisper-server"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Starts the server with this model (or reuses one already answering on the port). True once it answers.
    func start(model: URL) async -> Bool {
        let task: Task<Bool, Never> = {
            lock.lock(); defer { lock.unlock() }
            if let starting { return starting }
            let task = Task { await self.launch(model: model) }
            starting = task
            return task
        }()
        let ok = await task.value
        lock.lock()
        ready = ok
        starting = nil
        lock.unlock()
        return ok
    }

    private func launch(model: URL) async -> Bool {
        if await answers() {
            TimingLog.write("Whisper server already running on port \(Self.port)")
            return true
        }
        guard let binary = Self.findBinary() else {
            TimingLog.write("whisper-server not found — live words off, transcribing clip by clip")
            return false
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(Self.port), "-l", "en", "-nt"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            TimingLog.write("Whisper server failed to start: \(error.localizedDescription)")
            return false
        }
        lock.lock()
        self.process = process
        lock.unlock()

        let t0 = Date()
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !process.isRunning { break }
            if await answers() {
                TimingLog.write("Whisper server up in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                return true
            }
        }
        TimingLog.write("Whisper server didn't come up — transcribing clip by clip")
        process.terminate()
        return false
    }

    func stop() {
        lock.lock()
        let process = self.process
        self.process = nil
        ready = false
        starting?.cancel()
        starting = nil
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            TimingLog.write("Whisper server stopped")
        }
    }

    private func answers() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Text for a WAV clip. Throws if the server isn't there, so the caller can fall back to the CLI.
    func transcribe(wav: Data, prompt: String) async throws -> String {
        let boundary = "scriber-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("temperature", "0.0")
        field("response_format", "json")
        field("prompt", prompt)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw STTError.unavailable("Whisper server: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        if let error = object["error"] as? String { throw STTError.unavailable("Whisper server: \(error)") }
        return object["text"] as? String ?? ""
    }
}
