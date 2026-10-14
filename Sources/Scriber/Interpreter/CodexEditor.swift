import Foundation
import ScriberCore

/// One earlier exchange, so the editor can tell "no, not that" from a new request.
struct EditorTurn {
    var said: String
    var outcome: String
    var at: Date
}

/// What the writer marked in the draft: a selection to act on, wording to keep, paragraphs they approved.
struct DraftMarks: Sendable {
    /// Selected text and the paragraph numbers (1-based) it sits in.
    var selection: (text: String, paragraphs: [Int])?
    var locks: [String] = []
    /// Paragraph numbers (1-based) the writer approved.
    var approved: [Int] = []
    /// The plan from Structure mode, when there is one.
    var outline: String?
    /// The place the writer named by position ("paragraph two"), found in the draft.
    var pointed: String?
}

/// Sends the draft and what was said to ChatGPT through the Codex CLI (`codex exec`), signed in with the
/// ChatGPT account. Codex's own agent prompt and tools are swapped out for a short editing prompt, which keeps
/// a call around 6 s.
final class CodexEditor: @unchecked Sendable {
    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)
        case badReply(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Codex CLI not found — install with `npm i -g @openai/codex` and run `codex login`"
            case .failed(let message): return "Codex: \(message)"
            case .badReply(let raw): return "Codex returned something unexpected: \(raw.prefix(120))"
            }
        }
    }

    /// The thorough model: whole-draft rework, long briefs, Structure, Review.
    var model: String { UserDefaults.standard.string(forKey: "codexModel") ?? "gpt-5.6-sol" }
    /// The fast model for everyday edits.
    var fastModel: String { UserDefaults.standard.string(forKey: "codexFastModel") ?? "gpt-6-luna" }
    var effort: String { UserDefaults.standard.string(forKey: "codexEffort") ?? "low" }
    var displayName: String { "ChatGPT \(model) · \(effort)" }
    func displayName(fast: Bool) -> String { "ChatGPT \(fast ? fastModel : model) · \(effort)" }

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppSupport.folder.appendingPathComponent("codex", isDirectory: true)
    }()

    lazy var launch: (executable: URL, prefix: [String], path: String)? = Self.findCodex()

    var isAvailable: Bool { launch != nil }

    func edit(document: String, speech: String, history: [EditorTurn], context: ContextBundle,
              marks: DraftMarks = DraftMarks(), fast: Bool = false) async throws -> (CloudEdit, String) {
        let prompt = Self.prompt(document: document, speech: speech, history: history, context: context, marks: marks)
        let raw = try await json(kind: "edit", instructions: Self.instructions, schema: CloudEdit.schema, prompt: prompt,
                                 model: fast ? fastModel : model)
        guard let edit = CloudEdit.parse(raw) else { throw Failure.badReply(raw) }
        return (edit, raw)
    }

    /// One structured call: the instructions and schema for this kind of call, the prompt on stdin, JSON back.
    func json(kind: String, instructions: String, schema: [String: Any], prompt: String, model: String? = nil) async throws -> String {
        let model = model ?? self.model
        guard let launch else { throw Failure.notInstalled }
        let (instructionsFile, schemaFile) = try prepareFiles(kind: kind, instructions: instructions, schema: schema)
        let out = directory.appendingPathComponent("reply-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }

        let disabled = ["plugins", "apps", "browser_use", "browser_use_external", "computer_use", "hooks",
                        "skill_search", "tool_suggest", "goals", "shell_tool", "sleep_tool"]
        var args = launch.prefix + [
            "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
            "-s", "read-only", "-C", directory.path,
            "-m", model, "-c", "model_reasoning_effort=\(effort)",
            "-c", "model_instructions_file=\(instructionsFile.path)",
            "-c", "mcp_servers={}",
            "--output-schema", schemaFile.path,
            "-o", out.path
        ]
        for feature in disabled { args += ["--disable", feature] }
        // Codex otherwise adds ~4,800 tokens per call (the installed skills, multi-agent and sandbox instructions,
        // shell context) that an edit never needs; without them the same edit comes back ~3 s sooner.
        for setting in ["skills.include_instructions=false", "include_permissions_instructions=false",
                        "include_environment_context=false", "agents.enabled=false",
                        "features.multi_agent=false", "features.multi_agent_v2=false"] {
            args += ["-c", setting]
        }
        args.append("-")

        let (status, log) = try await Self.run(launch.executable, args, stdin: prompt, path: launch.path)
        guard status == 0 else {
            let line = log.split(separator: "\n").last(where: { $0.contains("ERROR") || $0.contains("rror") }) ?? Substring(log.suffix(200))
            throw Failure.failed(String(line.prefix(240)))
        }
        return (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    }

    // MARK: - Prompt

    static func prompt(document: String, speech: String, history: [EditorTurn], context: ContextBundle,
                       marks: DraftMarks = DraftMarks()) -> String {
        var parts = contextParts(context)
        if !history.isEmpty {
            let lines = history.map { "- Said: \"\($0.said)\"\n  Result: \($0.outcome)" }
            parts.append("EARLIER IN THIS SESSION (oldest first):\n" + lines.joined(separator: "\n"))
        }
        if let outline = marks.outline { parts.append("OUTLINE (the writer's plan):\n\(outline)") }
        parts.append("DRAFT:\n\(ParagraphEdits.numbered(document))")
        if !marks.locks.isEmpty {
            parts.append("LOCKED WORDING (keep word for word wherever it appears):\n"
                + marks.locks.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !marks.approved.isEmpty {
            parts.append("APPROVED: " + marks.approved.map { "p\($0)" }.joined(separator: ", "))
        }
        if let selection = marks.selection {
            let place = selection.paragraphs.map { "p\($0)" }.joined(separator: ", ")
            parts.append("SELECTION (the writer selected this in \(place) before speaking):\n\(selection.text)")
        }
        if let pointed = marks.pointed {
            parts.append("POINTED AT (the place SPEECH names by position, found in the draft):\n\(pointed)")
        }
        parts.append("SPEECH (just now):\n\(speech)")
        return parts.joined(separator: "\n\n")
    }

    /// Who's writing, how, and what about: the same for every kind of call.
    static func contextParts(_ context: ContextBundle) -> [String] {
        var parts: [String] = []
        let profile = context.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profile.isEmpty { parts.append("PROFILE (the writer):\n\(profile.prefix(1500))") }
        let style = context.style.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty { parts.append("WRITING STYLE:\n\(style.prefix(1500))") }
        let project = context.project.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty { parts.append("PROJECT NOTES:\n\(project.prefix(2000))") }
        let extra = context.extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { parts.append("MORE CONTEXT (files the writer added):\n\(extra.prefix(4000))") }
        let screen = context.screen.trimmingCharacters(in: .whitespacesAndNewlines)
        if !screen.isEmpty { parts.append("ON SCREEN:\n\(screen.prefix(6000))") }
        return parts
    }

    static let instructions = """
    You are the editor inside Whittle, a voice writing tool. The writer talks; you change the draft. You never run tools. You answer only with JSON matching the schema.

    THE DRAFT
    - Paragraphs are numbered [p1], [p2]… exactly like the ¶ numbers the writer sees. "Paragraph four" or "the fourth paragraph" is p4. Each line is its own paragraph, so a sign-off like "Best," and "Sam" are two.
    - The draft is written BY the writer TO its recipient. When the writer says "thank her for…", "tell him that she can…", "say that she doesn't need to…", the person they mean is the recipient: write "you".

    UNDERSTANDING SPEECH
    Speech comes from Whisper, so expect mis-heard words, especially names: prefer spellings already in the draft, PROFILE or project notes, and follow spelling corrections ("it's Haven, H-A-V-E-N").
    One utterance mixes:
    - asides and reactions ("yes, perfect", "hmm", "okay so") → nothing to do;
    - instructions ("add a paragraph after the greeting", "make it warmer", "delete the last part") → do them, never write them into the draft;
    - gists: what to say, in loose spoken words ("saying that it's totally fine she can't sponsor us", "thank her for the intro") → write it properly, in the draft's voice, keeping every point and adding none;
    - exact words ("say exactly…", "write: …", clearly dictated sentences) → keep the wording, fix only punctuation and capitalization.
    Do everything asked in the utterance, in order. When the writer reacts to the last change ("no, not like that", "you took that literally", "that's wrong"), fix that change rather than adding something new.
    If it's unclear what or where, change nothing and say what you couldn't do in could_not_do.

    EDITING
    - Change only what was asked. When you replace a paragraph to fix part of it, keep the rest word for word.
    - Don't invent facts, plans, compliments or pleasantries. A new email gets a greeting, exactly the content asked for, and a sign-off with the writer's name from PROFILE ("Best," then the name on the very next line, no blank line between).
    - New body text goes above the sign-off, never after it.
    - Ops: replace (id, text = the whole new paragraph), delete (id, text ""), insert_after / insert_before (id, text = the new paragraph). Use insert_after p0 for the very top or an empty draft. One op's text may hold several paragraphs separated by a blank line.
    - from_speech: copy the words of SPEECH that this op came from.
    - reply: "" unless the writer asked you a question or you must tell them something. When they ask a question ("does that transition work?", "just answer me…"), answer in reply and change nothing.

    FORMATTING
    - The draft can hold "• " bullets, "1. " numbered items, **bold** and *italic*. Each list item is its own line, and a list's items (and the lead-in line before them) are separated by a single line break, never a blank line. Use formatting only when the writer asks for it or the draft already uses it there; plain prose otherwise.
    - "Bullet points" / "make it a list": one idea per bullet, about 8–12 words, cut to the point (not whole sentences copied over), no full stop at the end, parallel wording. Keep every fact. A short lead-in line before the list is fine if the paragraph had one.
    - "Numbered" / "steps": the same, with "1. ", "2. " in order.
    - "Bold that" / "emphasize": wrap only the words meant, never a whole paragraph unless asked.

    ON SCREEN
    - Either text the writer selected in another app before opening Whittle, or text read (by OCR) from the window they were in, e.g. the email or thread they're replying to. Use it to understand who they're writing to and what about; names and facts in it are reliable spellings. It also contains menus, buttons and unrelated text: ignore those. Never copy it into the draft unless asked.

    MARKS
    - SELECTION: the writer selected that text before speaking. "This", "that", "it", "here" mean the selection. Change only the selection (keep the rest of its paragraph word for word) unless SPEECH clearly says otherwise.
    - LOCKED WORDING: exact words the writer dictated. Never change them; edits around them keep them verbatim.
    - APPROVED: paragraphs the writer said were good. Leave them unchanged unless SPEECH names them directly.
    - approved: ids of paragraphs SPEECH approves just now ("good, the opening works" → the opening's id, "I like the last paragraph"). [] otherwise.
    - POINTED AT: the passage SPEECH named by position ("paragraph two", "the last sentence"), already found for you. That's where the change goes unless SPEECH clearly says otherwise; keep the rest of its paragraph word for word.
    - OUTLINE: the writer's plan, section by section, with the points each must make. When asked to write sections, write each where the outline puts it and cover its points.
    """

    /// Each kind of call has its own instructions and schema; calls of one kind can run side by side.
    private func prepareFiles(kind: String, instructions: String, schema: [String: Any]) throws -> (URL, URL) {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let instructionsFile = directory.appendingPathComponent("instructions-\(kind).md")
        let schemaFile = directory.appendingPathComponent("schema-\(kind).json")
        let data = try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: schemaFile, options: .atomic)
        try instructions.write(to: instructionsFile, atomically: true, encoding: .utf8)
        return (instructionsFile, schemaFile)
    }

    // MARK: - Process

    /// Apps launched from Finder don't get the shell's PATH, so look where npm, Homebrew and nvm put it.
    static func findCodex() -> (URL, [String], String)? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            dirs = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" } + dirs
        }
        for dir in dirs {
            let codex = "\(dir)/codex"
            guard fm.isExecutableFile(atPath: codex) else { continue }
            let path = ([dir] + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
            let resolved = (try? fm.destinationOfSymbolicLink(atPath: codex)).map {
                $0.hasPrefix("/") ? $0 : URL(fileURLWithPath: dir).appendingPathComponent($0).standardized.path
            } ?? codex
            if resolved.hasSuffix(".js"), fm.isExecutableFile(atPath: "\(dir)/node") {
                return (URL(fileURLWithPath: "\(dir)/node"), [resolved], path)
            }
            return (URL(fileURLWithPath: codex), [], path)
        }
        return nil
    }

    static func run(_ executable: URL, _ args: [String], stdin: String, path: String) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, String), Error>) in
                var collected = Data()
                let lock = NSLock()
                output.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    lock.lock(); collected.append(chunk); lock.unlock()
                }
                process.terminationHandler = { p in
                    output.fileHandleForReading.readabilityHandler = nil
                    let rest = output.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); collected.append(rest); let data = collected; lock.unlock()
                    continuation.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
                }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                        if process.isRunning { process.terminate() }
                    }
                    input.fileHandleForWriting.write(Data(stdin.utf8))
                    try? input.fileHandleForWriting.close()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
