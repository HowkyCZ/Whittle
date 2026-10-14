import Foundation

public enum IntentKind: String, Codable, Sendable {
    case dictate
    case compose
    case edit
    case discuss
}

public struct InterpreterResponse: Equatable, Sendable {
    public var intent: IntentKind
    public var assistantMessage: String?
    public var ops: [DocumentOp]
    public var spans: [SpeechSpan]
    public var rawJSON: String?

    public init(
        intent: IntentKind,
        assistantMessage: String?,
        ops: [DocumentOp],
        spans: [SpeechSpan] = [],
        rawJSON: String? = nil
    ) {
        self.intent = intent
        self.assistantMessage = assistantMessage
        self.ops = ops
        self.spans = spans
        self.rawJSON = rawJSON
    }
}

public struct ContextBundle: Sendable {
    public var profile: String
    public var style: String
    public var project: String
    public var projectName: String
    /// Files the writer added to this draft by hand.
    public var extra: String
    /// Text read from the window the writer came from, e.g. the email they're replying to.
    public var screen: String

    public init(profile: String, style: String, project: String, projectName: String, extra: String = "", screen: String = "") {
        self.profile = profile
        self.style = style
        self.project = project
        self.projectName = projectName
        self.extra = extra
        self.screen = screen
    }
}

public struct UtteranceTurn: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        case applied
        case discussed
        case interrupt
        case failed
        case queued
        case heard
    }

    public let id: UUID
    public var transcript: String
    public var intent: IntentKind?
    public var explanation: String
    public var outcome: Outcome
    public var spans: [SpeechSpan]

    public init(
        id: UUID = UUID(),
        transcript: String,
        intent: IntentKind? = nil,
        explanation: String = "",
        outcome: Outcome = .heard,
        spans: [SpeechSpan] = []
    ) {
        self.id = id
        self.transcript = transcript
        self.intent = intent
        self.explanation = explanation
        self.outcome = outcome
        self.spans = spans
    }
}

public protocol InterpreterClient: AnyObject {
    func warm() async
    var modelName: String { get }
    func label(clauses: [Clause], document: String) async throws -> ClauseLabeling
    func proposeEdits(
        utterance: String,
        document: String,
        revision: Int,
        context: ContextBundle,
        lastAssistant: String,
        recentUtterances: [String],
        spans: [SpeechSpan],
        forcedIntent: IntentKind?,
        retryHint: String?
    ) async throws -> InterpreterResponse
    func checkParagraph(_ paragraph: String, document: String) async throws -> ParagraphVerdict
    /// Rewrites one passage of the draft; returns only the replacement text.
    func rewrite(passage: String, how: String, document: String, context: ContextBundle) async throws -> String
}

public enum InterruptLexicon {
    public enum Kind: Equatable { case undo, cancel }

    /// "no" alone is too dangerous (STT often hallucinates it). Only cancel
    /// when there is an in-flight edit, or the phrase is unambiguously stop.
    public static func match(_ utterance: String, hasInFlight: Bool) -> Kind? {
        let t = utterance.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)

        let undoPhrases = ["undo", "undo that"]
        if undoPhrases.contains(t) { return .undo }

        let cancelPhrases = ["stop", "wait", "cancel", "hold on"]
        if cancelPhrases.contains(t) { return .cancel }

        if hasInFlight && (t == "no" || t == "nope") { return .cancel }
        return nil
    }
}

public enum EscapePhrases {
    public static func forceIntent(_ utterance: String, documentIsEmpty: Bool) -> IntentKind? {
        let t = utterance.lowercased()
        if t.contains("say exactly") || t.contains("write exactly") {
            return .dictate
        }
        if t.contains("don't edit") || t.contains("dont edit")
            || t.contains("just answer") || t.contains("just answer me") {
            return .discuss
        }
        return nil
    }
}

public enum InterpreterJSON {
    public static func parse(
        _ raw: String,
        forcedIntent: IntentKind?,
        utterance: String
    ) throws -> InterpreterResponse {
        guard let obj = decodeObject(raw) else {
            throw InterpreterJSONError.badJSON(raw)
        }

        var message = obj["assistant_message"] as? String
        if message?.isEmpty == true { message = nil }

        let spans = parseSpans(obj["spans"])

        if let action = (obj["action"] as? String)?.lowercased() {
            if message == nil, let note = obj["note"] as? String, !note.isEmpty { message = note }
            var reply = writerReply(action: action, find: obj["find"] as? String, text: obj["text"] as? String)
            if let forcedIntent { reply.intent = forcedIntent }
            if reply.intent == .discuss { reply.ops = [] }
            if reply.intent == .dictate, reply.ops.isEmpty {
                let exact = stripDictatePrefix(utterance)
                if !exact.isEmpty { reply.ops = [DocumentOp(op: .append, text: exact)] }
            }
            return InterpreterResponse(intent: reply.intent, assistantMessage: message, ops: reply.ops, spans: spans, rawJSON: raw)
        }

        let opsRaw = obj["ops"] as? [[String: Any]] ?? []
        var ops: [DocumentOp] = opsRaw.compactMap { dict in
            guard let opStr = (dict["op"] as? String)?.lowercased(),
                  let op = DocumentOpType(rawValue: opStr) else { return nil }
            return DocumentOp(
                op: op,
                start: intValue(dict["start"]),
                end: intValue(dict["end"]),
                text: dict["text"] as? String,
                anchor: dict["anchor"] as? String,
                destination: intValue(dict["destination"]),
                target: dict["target"] as? String
            )
        }

        let intentStr = (obj["intent"] as? String)?.lowercased() ?? ""
        var intent = Self.normalizeIntent(intentStr, ops: ops)
        if let forcedIntent { intent = forcedIntent }

        if intent == .discuss {
            return InterpreterResponse(intent: .discuss, assistantMessage: message, ops: [], spans: spans, rawJSON: raw)
        }

        let meaningful = ops.filter { $0.op != .noDocumentChange }
        if meaningful.isEmpty, intent == .dictate {
            let exact = stripDictatePrefix(utterance)
            if !exact.isEmpty {
                ops = [DocumentOp(op: .append, text: exact)]
            }
        }

        return InterpreterResponse(intent: intent, assistantMessage: message, ops: ops, spans: spans, rawJSON: raw)
    }

    /// Maps the writer's single action onto document ops. Text-bearing actions without text become discuss.
    public static func writerReply(action: String, find: String?, text: String?) -> (intent: IntentKind, ops: [DocumentOp]) {
        let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = (find ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "append":
            guard !body.isEmpty else { return (.discuss, []) }
            return (.compose, [DocumentOp(op: .append, text: body)])
        case "replace":
            guard !body.isEmpty else { return (.discuss, []) }
            if anchor.isEmpty {
                return (.edit, [DocumentOp(op: .replace, text: body, target: "last_paragraph")])
            }
            return (.edit, [DocumentOp(op: .replace, text: body, anchor: anchor)])
        case "replace_all", "rewrite":
            guard !body.isEmpty else { return (.discuss, []) }
            return (.edit, [DocumentOp(op: .replace, text: body, target: "whole_document")])
        case "delete":
            if anchor.isEmpty { return (.edit, [DocumentOp(op: .delete, target: "last_paragraph")]) }
            return (.edit, [DocumentOp(op: .delete, anchor: anchor)])
        default:
            return (.discuss, [])
        }
    }

    public static func parseClauseLabels(_ raw: String, clauseCount: Int) -> ClauseLabeling {
        guard let obj = decodeObject(raw) else { return ClauseLabeling(labels: [], complete: nil) }
        let complete = obj["complete"] as? Bool
        let arr = obj["labels"] as? [[String: Any]] ?? []
        let labels: [ClauseLabel] = arr.compactMap { dict in
            guard let i = intValue(dict["i"]) ?? intValue(dict["index"]),
                  (1...max(clauseCount, 1)).contains(i),
                  let roleStr = dict["role"] as? String,
                  let role = SpanRole.parse(roleStr) else { return nil }
            let focus = (dict["focus"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ClauseLabel(index: i, role: role, focus: focus)
        }
        return ClauseLabeling(labels: labels, complete: complete)
    }

    public static func parseSpans(_ any: Any?) -> [SpeechSpan] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let roleStr = dict["role"] as? String,
                  let role = SpanRole.parse(roleStr),
                  let quote = dict["quote"] as? String else { return nil }
            let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SpeechSpan(role: role, quote: trimmed)
        }
    }

    public static func extractJSONObject(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return balancedObject(trimmed) }
        if let fence = trimmed.range(of: "```") {
            let after = trimmed[fence.upperBound...]
            let body = after.replacingOccurrences(of: "json", with: "", options: [.anchored, .caseInsensitive])
            return balancedObject(body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let start = trimmed.firstIndex(of: "{") {
            return balancedObject(String(trimmed[start...]))
        }
        return nil
    }

    private static func decodeObject(_ raw: String) -> [String: Any]? {
        guard let json = extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func balancedObject(_ s: String) -> String? {
        var depth = 0
        var start: String.Index?
        for i in s.indices {
            let c = s[i]
            if c == "{" {
                if start == nil { start = i }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0, let start {
                    return String(s[start...i])
                }
            }
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func normalizeIntent(_ raw: String, ops: [DocumentOp]) -> IntentKind {
        if let known = IntentKind(rawValue: raw) { return known }
        let aliases: [(IntentKind, [String])] = [
            (.compose, ["write", "draft", "generate", "create", "email", "compose"]),
            (.dictate, ["exact", "verbatim", "dictate"]),
            (.edit, ["edit", "change", "revise", "rewrite", "shorten"]),
            (.discuss, ["discuss", "question", "ask", "talk"])
        ]
        for (kind, keys) in aliases where keys.contains(where: { raw.contains($0) }) {
            return kind
        }
        let mutating = ops.contains { $0.op != .noDocumentChange }
        return mutating ? .compose : .discuss
    }

    private static func stripDictatePrefix(_ utterance: String) -> String {
        var t = utterance
        let prefixes = ["write exactly:", "write exactly", "say exactly:", "say exactly"]
        let lower = t.lowercased()
        for p in prefixes where lower.hasPrefix(p) {
            t = String(t.dropFirst(p.count))
            break
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum InterpreterJSONError: LocalizedError {
    case badJSON(String)
    public var errorDescription: String? {
        switch self {
        case .badJSON(let raw):
            return "Could not parse interpreter JSON: \(raw.prefix(200))"
        }
    }
}

public enum TurnLog {
    public static func write(_ object: [String: Any]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: TimingLog.directory, withIntermediateDirectories: true)
        let file = TimingLog.directory.appendingPathComponent("turns.jsonl")
        var payload = object
        payload["ts"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let row = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: file.path) {
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: row)
            }
        } else {
            try? row.write(to: file)
        }
    }
}

public enum TimingLog {
    public static var directory: URL {
        AppSupport.folder.appendingPathComponent("logs", isDirectory: true)
    }

    public static func write(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("timing.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let row = "[\(stamp)] \(line)\n"
        if let data = row.data(using: .utf8) {
            if fm.fileExists(atPath: file.path) {
                if let handle = try? FileHandle(forWritingTo: file) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: file)
            }
        }
    }
}
