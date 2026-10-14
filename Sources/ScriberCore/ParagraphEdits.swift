import Foundation

/// The cloud editor's contract: the draft goes out as numbered paragraphs ([p1], [p2]… matching ¶1, ¶2 in the
/// margin) and edits come back as operations on those ids. Nothing has to be quoted back exactly.
public struct ParagraphOp: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case replace
        case insertAfter = "insert_after"
        case insertBefore = "insert_before"
        case delete
    }

    public var op: Kind
    public var id: String
    public var text: String
    /// The words of the speech that caused this op.
    public var fromSpeech: String

    enum CodingKeys: String, CodingKey {
        case op, id, text
        case fromSpeech = "from_speech"
    }

    public init(op: Kind, id: String, text: String = "", fromSpeech: String = "") {
        self.op = op
        self.id = id
        self.text = text
        self.fromSpeech = fromSpeech
    }
}

public struct CloudEdit: Codable, Equatable, Sendable {
    public var ops: [ParagraphOp]
    /// An answer when the speaker asked something; empty otherwise.
    public var reply: String
    /// Things that were asked but couldn't be done, in the speaker's terms.
    public var couldNotDo: [String]
    /// Paragraph ids the speaker approved ("good, the opening works"), numbered as in the draft that was sent.
    public var approved: [String]

    enum CodingKeys: String, CodingKey {
        case ops, reply, approved
        case couldNotDo = "could_not_do"
    }

    public init(ops: [ParagraphOp], reply: String = "", couldNotDo: [String] = [], approved: [String] = []) {
        self.ops = ops
        self.reply = reply
        self.couldNotDo = couldNotDo
        self.approved = approved
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ops = try c.decode([ParagraphOp].self, forKey: .ops)
        reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
        couldNotDo = try c.decodeIfPresent([String].self, forKey: .couldNotDo) ?? []
        approved = try c.decodeIfPresent([String].self, forKey: .approved) ?? []
    }

    public static func parse(_ raw: String) -> CloudEdit? {
        guard let json = InterpreterJSON.extractJSONObject(raw), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CloudEdit.self, from: data)
    }

    /// JSON schema for structured output. Strict mode needs every field required and no extras.
    public static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["ops", "reply", "could_not_do", "approved"],
        "properties": [
            "ops": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["op", "id", "text", "from_speech"],
                    "properties": [
                        "op": ["type": "string", "enum": ["replace", "insert_after", "insert_before", "delete"]],
                        "id": ["type": "string"],
                        "text": ["type": "string"],
                        "from_speech": ["type": "string"]
                    ]
                ]
            ],
            "reply": ["type": "string"],
            "could_not_do": ["type": "array", "items": ["type": "string"]],
            "approved": ["type": "array", "items": ["type": "string"]]
        ]
    ]
}

public enum ParagraphEdits {
    public enum Failure: Error, Equatable, LocalizedError {
        case unknownParagraph(String)
        /// The paragraph changed after the request was sent.
        case conflict(String)

        public var errorDescription: String? {
            switch self {
            case .unknownParagraph(let id): return "The edit pointed at \(id), which isn't in the draft"
            case .conflict(let id): return "\(id) changed while the edit was being written"
            }
        }
    }

    /// "[p1] Hi Lena,\n[p2] Thank you…" — one line per paragraph as numbered in the margin.
    public static func numbered(_ document: String) -> String {
        let paragraphs = DocumentParagraphs.split(document)
        if paragraphs.isEmpty { return "(empty — use insert_after p0)" }
        return paragraphs.enumerated().map { "[p\($0.offset + 1)] \($0.element.text)" }.joined(separator: "\n")
    }

    /// Applies ops written against `sent` to `current`. Paragraphs are matched between the two by text,
    /// so edits to other paragraphs in the meantime are kept; an op on a paragraph that changed is a conflict.
    public static func apply(_ ops: [ParagraphOp], sent: String, current: String) throws -> String {
        let sentParagraphs = DocumentParagraphs.split(sent).map(\.text)
        let units = Unit.split(current)
        let mapping = align(sentParagraphs, units.map(\.text))

        var replaced: [Int: [String]] = [:]
        var before: [Int: [String]] = [:]
        var after: [Int: [String]] = [:]
        var top: [String] = []

        for op in ops {
            let text = tightenSignOff(op.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let n = number(op.id) else { throw Failure.unknownParagraph(op.id) }
            if n == 0 {
                guard op.op == .insertAfter || op.op == .insertBefore else { throw Failure.unknownParagraph(op.id) }
                if !text.isEmpty { top.append(text) }
                continue
            }
            guard sentParagraphs.indices.contains(n - 1) else { throw Failure.unknownParagraph(op.id) }
            guard let index = mapping[n - 1] else { throw Failure.conflict(op.id) }
            switch op.op {
            case .replace:
                replaced[index, default: []].append(contentsOf: text.isEmpty ? [] : [text])
            case .delete:
                replaced[index] = replaced[index] ?? []
            case .insertAfter:
                if !text.isEmpty { after[index, default: []].append(text) }
            case .insertBefore:
                if !text.isEmpty { before[index, default: []].append(text) }
            }
        }

        // Each output piece remembers which original paragraph it came from, to keep original line breaks.
        var pieces: [(text: String, original: Int?)] = top.map { ($0, nil) }
        for (i, unit) in units.enumerated() {
            pieces += (before[i] ?? []).map { ($0, nil) }
            if let replacement = replaced[i] {
                pieces += replacement.enumerated().map { ($0.element, $0.offset == 0 ? i : nil) }
            } else {
                pieces.append((unit.text, i))
            }
            pieces += (after[i] ?? []).map { ($0, nil) }
        }

        var out = units.first?.leading ?? ""
        for (k, piece) in pieces.enumerated() {
            out += piece.text
            guard k + 1 < pieces.count else { break }
            let next = pieces[k + 1]
            if let a = piece.original, let b = next.original, b == a + 1 {
                out += units[a].separator
            } else if DraftFormat.isListItem(DraftFormat.normalized(lastLine(piece.text))),
                      DraftFormat.isListItem(DraftFormat.normalized(next.text)) {
                // Items of one list sit on consecutive lines.
                out += "\n"
            } else {
                out += "\n\n"
            }
        }
        return out
    }

    static func lastLine(_ text: String) -> String {
        text.components(separatedBy: "\n").last ?? text
    }

    /// "Best,\n\nSam" → "Best,\nSam": the name sits right under the sign-off.
    static func tightenSignOff(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(^|\n)((?i:best|cheers|thanks|many thanks|kind regards|regards|all the best|warmly|warm regards|talk soon)[,!]?)[ \t]*\n[ \t]*\n[ \t]*([A-Z][\p{L}'’.-]*(?:[ \t]+[A-Z][\p{L}'’.-]*){0,2})\s*$"#,
            with: "$1$2\n$3",
            options: .regularExpression
        )
    }

    public static func number(_ id: String) -> Int? {
        let digits = id.trimmingCharacters(in: CharacterSet(charactersIn: "[]¶pP "))
        return Int(digits)
    }

    /// Longest common subsequence on exact text: sent index → current index.
    static func align(_ a: [String], _ b: [String]) -> [Int: Int] {
        if a == b { return Dictionary(uniqueKeysWithValues: a.indices.map { ($0, $0) }) }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var mapping: [Int: Int] = [:]
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { mapping[i] = j; i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return mapping
    }

    /// A paragraph with the whitespace that follows it.
    struct Unit {
        var text: String
        var separator: String
        var leading: String

        static func split(_ document: String) -> [Unit] {
            let ns = document as NSString
            let paragraphs = DocumentParagraphs.split(document)
            return paragraphs.enumerated().map { k, p in
                let end = p.range.location + p.range.length
                let nextStart = k + 1 < paragraphs.count ? paragraphs[k + 1].range.location : end
                let separator = ns.substring(with: NSRange(location: end, length: max(0, nextStart - end)))
                let leading = k == 0 ? ns.substring(to: p.range.location) : ""
                return Unit(text: p.text, separator: separator, leading: leading)
            }
        }
    }

    /// "Rewrote ¶4 · Added after ¶3" for the panel and the logs.
    public static func describe(_ ops: [ParagraphOp]) -> String {
        if ops.isEmpty { return "No change" }
        return ops.map { op in
            let label = number(op.id).map { $0 == 0 ? "the top" : "¶\($0)" } ?? op.id
            switch op.op {
            case .replace: return "Rewrote \(label)"
            case .delete: return "Removed \(label)"
            case .insertAfter: return label == "the top" ? "Added at the top" : "Added after \(label)"
            case .insertBefore: return "Added before \(label)"
            }
        }.joined(separator: " · ")
    }
}
