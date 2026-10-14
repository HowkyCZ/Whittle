import Foundation

/// A reviewer in Review mode: a name, what it looks for, and its colour in the draft.
public struct ReviewAgent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var brief: String
    /// "#RRGGBB".
    public var color: String
    public var enabled: Bool

    public init(id: String, name: String, brief: String, color: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.brief = brief
        self.color = color
        self.enabled = enabled
    }

    public static let defaults: [ReviewAgent] = [
        ReviewAgent(id: "skeptic", name: "Skeptic", brief: "Pushes on weak or vague claims", color: "#B8452F"),
        ReviewAgent(id: "cutter", name: "Cutter", brief: "Finds what can go", color: "#C98A3A"),
        ReviewAgent(id: "factcheck", name: "Fact check", brief: "Checks against your context files", color: "#3F7A70"),
        ReviewAgent(id: "reader", name: "Reader", brief: "Reads it as the recipient", color: "#A85F73"),
        ReviewAgent(id: "tone", name: "Tone", brief: "Checks against writing-style", color: "#6A5A8C", enabled: false),
    ]

    /// The defaults' colours before the clay and dusky slate palette, so saved agents can be moved over.
    public static let previousDefaultColors = ["skeptic": "#E5484D", "cutter": "#E79D13", "factcheck": "#12A594",
                                               "reader": "#D6409F", "tone": "#3E63DD"]

    /// Colours for agents the writer adds, after the defaults'; muted to sit with them.
    public static let palette = ["#5E7A95", "#8C6A3F", "#7A6A9C", "#5F8A6E", "#9C5F7A", "#A0703F", "#4F7F8C"]

    /// Saved agents keep their names and switches; default agents still on an old default colour get the new one.
    public static func updatingColors(_ saved: [ReviewAgent]) -> [ReviewAgent] {
        saved.map { agent in
            guard previousDefaultColors[agent.id] == agent.color,
                  let current = defaults.first(where: { $0.id == agent.id }) else { return agent }
            var agent = agent
            agent.color = current.color
            return agent
        }
    }
}

/// One line in a conversation with an agent.
public struct ReviewMessage: Equatable, Sendable {
    public enum From: Equatable, Sendable { case agent, writer }
    public var from: From
    public var text: String

    public init(from: From, text: String) {
        self.from = from
        self.text = text
    }
}

/// An agent's comment on a passage of the draft.
public struct ReviewComment: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case open
        /// Will go to the editor as it is.
        case approved
        /// The writer is talking it over with the agent.
        case talking
        /// The conversation ended with something for the editor to do.
        case concluded
    }

    public var id: UUID
    public var agentID: String
    public var quote: String
    /// Where the quote is in the draft (UTF-16).
    public var range: NSRange
    public var message: String
    public var state: State
    public var thread: [ReviewMessage]
    /// What the conversation settled, for the editor.
    public var conclusion: String

    public init(id: UUID = UUID(), agentID: String, quote: String, range: NSRange, message: String,
                state: State = .open, thread: [ReviewMessage] = [], conclusion: String = "") {
        self.id = id
        self.agentID = agentID
        self.quote = quote
        self.range = range
        self.message = message
        self.state = state
        self.thread = thread
        self.conclusion = conclusion
    }

    /// Counts towards "Send N to editor".
    public var isForEditor: Bool { state == .approved || state == .concluded }
}

/// What an agent sends back when it reads the draft.
public struct AgentReview: Codable, Equatable, Sendable {
    public struct Comment: Codable, Equatable, Sendable {
        public var quote: String
        public var comment: String

        public init(quote: String, comment: String) {
            self.quote = quote
            self.comment = comment
        }
    }

    public var comments: [Comment]

    public init(comments: [Comment]) { self.comments = comments }

    public static func parse(_ raw: String) -> AgentReview? {
        guard let json = InterpreterJSON.extractJSONObject(raw), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentReview.self, from: data)
    }

    public static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["comments"],
        "properties": [
            "comments": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["quote", "comment"],
                    "properties": ["quote": ["type": "string"], "comment": ["type": "string"]]
                ]
            ]
        ]
    ]
}

/// An agent's answer when the writer replies to its comment.
public struct AgentReply: Codable, Equatable, Sendable {
    public var reply: String
    /// What the editor should change, given the conversation so far; "" for nothing.
    public var conclusion: String

    public init(reply: String, conclusion: String) {
        self.reply = reply
        self.conclusion = conclusion
    }

    public static func parse(_ raw: String) -> AgentReply? {
        guard let json = InterpreterJSON.extractJSONObject(raw), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentReply.self, from: data)
    }

    public static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["reply", "conclusion"],
        "properties": ["reply": ["type": "string"], "conclusion": ["type": "string"]]
    ]
}

public enum ReviewText {
    /// Where a quoted passage is in the draft. Models copy quotes loosely, so this tries the exact text,
    /// then without case, quotes and outer punctuation, then with any run of spaces matching any other.
    public static func locate(_ quote: String, in draft: String) -> NSRange? {
        let ns = draft as NSString
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let exact = ns.range(of: trimmed)
        if exact.location != NSNotFound { return exact }
        let loose = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’.,;:…").union(.whitespaces))
        guard !loose.isEmpty else { return nil }
        let folded = ns.range(of: loose, options: [.caseInsensitive, .diacriticInsensitive])
        if folded.location != NSNotFound { return folded }
        let words = loose.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty, let regex = try? NSRegularExpression(pattern: words.joined(separator: "\\s+"), options: [.caseInsensitive]) else {
            return nil
        }
        return regex.firstMatch(in: draft, range: NSRange(location: 0, length: ns.length))?.range
    }

    /// The request for the editor: the comments the writer approved and what the conversations settled, as one batch.
    public static func editorRequest(_ comments: [ReviewComment], agents: [ReviewAgent], draft: String) -> String? {
        let ns = draft as NSString
        let items = comments.filter(\.isForEditor).sorted { $0.range.location < $1.range.location }.map { comment -> String in
            let name = agents.first { $0.id == comment.agentID }?.name ?? "A reviewer"
            let passage = NSMaxRange(comment.range) <= ns.length ? ns.substring(with: comment.range) : comment.quote
            if comment.state == .concluded, !comment.conclusion.isEmpty {
                return "- On “\(passage)”: \(comment.conclusion) (agreed with \(name))"
            }
            return "- On “\(passage)”: \(comment.message) (\(name))"
        }
        guard !items.isEmpty else { return nil }
        return (["Make these changes from review, all in one go. Each is about the quoted passage. Change only what they ask; keep everything else word for word."]
            + items).joined(separator: "\n")
    }
}
