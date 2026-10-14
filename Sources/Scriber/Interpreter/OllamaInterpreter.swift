import Foundation
import ScriberCore

/// Local LLM via Ollama HTTP API. Two calls: label clauses, then (if needed) emit ops.
final class OllamaInterpreter: InterpreterClient {
    var baseURL = URL(string: "http://127.0.0.1:11434")!
    private(set) var model = "llama3.2"
    var modelName: String { model }

    /// Labeling clauses well needs more than a 3B model; use the strongest one installed.
    private static let preferredModels = [
        "qwen2.5:14b", "qwen2.5:7b", "qwen2.5:7b-instruct", "llama3.1:8b", "llama3.2"
    ]

    private var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    func warm() async {
        await pickModel()
        _ = try? await chat(messages: [
            ["role": "system", "content": "Reply with OK"],
            ["role": "user", "content": "OK"]
        ], mode: .plain)
    }

    private func pickModel() async {
        let url = baseURL.appendingPathComponent("api/tags")
        guard let (data, _) = try? await session.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return }
        let installed = Set(models.compactMap { $0["name"] as? String })
        for name in Self.preferredModels {
            if installed.contains(name) || installed.contains("\(name):latest") {
                model = name
                return
            }
        }
    }

    private enum ChatMode { case plain, json, schema([String: Any]) }

    func label(clauses: [Clause], document: String) async throws -> ClauseLabeling {
        await pickModel()
        let messages: [[String: String]] = [
            ["role": "system", "content": Self.labelSystemPrompt],
            ["role": "user", "content": Self.labelUserPrompt(clauses: clauses, document: document)]
        ]
        let raw: String
        do {
            raw = try await chat(messages: messages, mode: .schema(Self.labelSchema))
        } catch {
            raw = try await chat(messages: messages, mode: .json)
        }
        return InterpreterJSON.parseClauseLabels(raw, clauseCount: clauses.count)
    }

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
    ) async throws -> InterpreterResponse {
        let user = Self.actUserPrompt(
            utterance: utterance,
            document: document,
            revision: revision,
            context: context,
            lastAssistant: lastAssistant,
            recentUtterances: recentUtterances,
            spans: spans,
            forcedIntent: forcedIntent,
            retryHint: retryHint
        )
        let messages: [[String: String]] = [
            ["role": "system", "content": Self.actSystemPrompt],
            ["role": "user", "content": user]
        ]
        let raw: String
        do {
            raw = try await chat(messages: messages, mode: .schema(Self.writerSchema))
        } catch {
            raw = try await chat(messages: messages, mode: .json)
        }
        var parsed = try InterpreterJSON.parse(raw, forcedIntent: forcedIntent, utterance: utterance)
        parsed.spans = spans
        parsed.rawJSON = raw
        return parsed
    }

    func checkParagraph(_ paragraph: String, document: String) async throws -> ParagraphVerdict {
        let messages: [[String: String]] = [
            ["role": "system", "content": Self.polishSystemPrompt],
            ["role": "user", "content": "DRAFT:\n\(Self.truncate(document, 3000))\n\nPARAGRAPH:\n\(paragraph)"]
        ]
        let raw = try await chat(messages: messages, mode: .schema(Self.polishSchema), temperature: 0)
        guard let json = InterpreterJSON.extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = (obj["kind"] as? String).flatMap(ParagraphVerdict.Kind.init(rawValue:)) else {
            throw InterpreterError.badResponse(raw)
        }
        return ParagraphVerdict(kind: kind, clean: obj["clean"] as? String ?? "")
    }

    func rewrite(passage: String, how: String, document: String, context: ContextBundle) async throws -> String {
        let user = """
        PROFILE:
        \(Self.truncate(context.profile, 1500))

        STYLE:
        \(Self.truncate(context.style, 1500))

        DRAFT:
        \(Self.truncate(document, 4000))

        PASSAGE:
        \(passage)

        INSTRUCTION: make it \(how)
        """
        let messages: [[String: String]] = [
            ["role": "system", "content": Self.rewriteSystemPrompt],
            ["role": "user", "content": user]
        ]
        let raw = try await chat(messages: messages, mode: .schema(Self.rewriteSchema))
        guard let json = InterpreterJSON.extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterpreterError.badResponse(raw)
        }
        return text
    }

    private func chat(messages: [[String: String]], mode: ChatMode, temperature: Double = 0.15) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            // Stay loaded between utterances: a cold load is what made some labels take 10–40 s.
            "keep_alive": "30m",
            "options": [
                "temperature": temperature
            ]
        ]
        switch mode {
        case .plain:
            break
        case .json:
            body["format"] = "json"
        case .schema(let schema):
            body["format"] = schema
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw InterpreterError.ollamaUnreachable(
                "Ollama not reachable at \(baseURL). Run `brew services start ollama` and `ollama pull \(model)`."
            )
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw InterpreterError.badResponse(text)
        }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = obj?["message"] as? [String: Any]
        guard let content = message?["content"] as? String else {
            throw InterpreterError.badResponse("Missing message.content")
        }
        return content
    }

    static let labelSystemPrompt = """
    A person is speaking to a writing tool that edits a document. Their speech was split into numbered clauses.
    Label EVERY clause with one role. You never write the document.

    Roles:
    - aside: talk to the tool, not content: "okay", "so", "this looks great", "that's not ideal", "hmm", complaints, thinking aloud
    - ask: an instruction to the tool. "let's write an email to Lena", "write a thank you email", "delete that", "make it shorter", "edit it". Asks are never pasted into the document.
    - gist: what the text should say, in the speaker's paraphrase: "thanking her for connecting me with Haven Founders". Rambling or hedged speech is gist even after "say": "maybe like we will, you know, reach out if…"
    - words: exact, clean wording the speaker wants on the page: "really appreciate it", "cheers Sam"
    - where: points at existing document text or a position: "the first paragraph", "connecting with someone from Haven Founders" when that text is in the document
    - tone: style or length: "short", "not too formal"

    focus: for where/words/gist only, the exact sub-phrase of the clause that IS the text, without framing words like "say", "instead of saying", "I wouldn't say". Omit otherwise.

    complete: false if the speaker trailed off mid-thought (ends on "with", "from", "to", an unfinished ask, or an unfinished name). true otherwise.

    Example A (document empty)
    1. Okay, so let's write an email
    2. thanking her for connecting me with someone from Haven Founders.
    → {"complete":true,"labels":[{"i":1,"role":"ask"},{"i":2,"role":"gist"}]}

    Example B (document contains "connecting me with someone from Haven Founders")
    1. Okay,
    2. I wouldn't
    3. say with someone from Haven Founders,
    4. you can just say with Haven Founders.
    → {"complete":true,"labels":[{"i":1,"role":"aside"},{"i":2,"role":"ask"},{"i":3,"role":"where","focus":"with someone from Haven Founders"},{"i":4,"role":"words","focus":"with Haven Founders"}]}

    Example C (document empty)
    1. Create an email to Lena
    2. saying thank you for connecting me with Haven Founders,
    3. really appreciate it,
    4. cheers Sam.
    → {"complete":true,"labels":[{"i":1,"role":"ask"},{"i":2,"role":"words","focus":"thank you for connecting me with Haven Founders"},{"i":3,"role":"words"},{"i":4,"role":"words"}]}

    Example D
    1. Let's write an email saying thank you to Lena for connecting me with
    → {"complete":false,"labels":[{"i":1,"role":"ask"}]}

    Example E (document has text)
    1. That's not ideal, okay.
    2. You should just write the email,
    3. not put in what I said.
    → {"complete":true,"labels":[{"i":1,"role":"aside"},{"i":2,"role":"ask"},{"i":3,"role":"ask"}]}

    Example F (document contains "someone from Haven Founders")
    1. instead of saying someone from Haven Founders,
    2. just say with Haven Founders.
    → {"complete":true,"labels":[{"i":1,"role":"where","focus":"someone from Haven Founders"},{"i":2,"role":"words","focus":"with Haven Founders"}]}

    Example G (document has an email). Everything after "saying" belongs to the new text, including "by the way" and hedges.
    1. No,
    2. no,
    3. delete the last part you said.
    4. Then add another paragraph
    5. saying,
    6. by the way,
    7. totally understandable that you can't sponsor right now.
    8. And
    9. just say maybe like we will,
    10. you know,
    11. reach out if we come across other ways you could support.
    → {"complete":true,"labels":[{"i":1,"role":"aside"},{"i":2,"role":"aside"},{"i":3,"role":"ask"},{"i":4,"role":"ask"},{"i":5,"role":"ask"},{"i":6,"role":"words"},{"i":7,"role":"words"},{"i":8,"role":"ask"},{"i":9,"role":"gist","focus":"maybe like we will"},{"i":10,"role":"gist"},{"i":11,"role":"gist"}]}

    Example H (document contains "connecting me with someone from Haven Founders"). "you say X" quotes what the document says now.
    1. And in the email,
    2. you
    3. say connecting me with someone from Haven Founders.
    4. Just say connecting me with Haven Founders.
    → {"complete":true,"labels":[{"i":1,"role":"where"},{"i":2,"role":"where"},{"i":3,"role":"where","focus":"connecting me with someone from Haven Founders"},{"i":4,"role":"words","focus":"connecting me with Haven Founders"}]}

    Return ONLY JSON: {"complete": bool, "labels": [{"i": n, "role": "...", "focus": "..."}]}
    """

    static func labelUserPrompt(clauses: [Clause], document: String) -> String {
        let doc = document.isEmpty ? "(empty)" : truncate(document, 3000)
        let numbered = clauses.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        return "CURRENT_DOCUMENT:\n\(doc)\n\nCLAUSES:\n\(numbered)"
    }

    static let actSystemPrompt = """
    You are the writer inside Whittle, a voice writing tool. The speaker's utterance is already split into labeled spans. Pick ONE action on CURRENT_DOCUMENT and write the actual document text.

    Actions:
    - append: add new text at the end. text = only the new text.
    - replace: change one part. find = an exact passage copied from CURRENT_DOCUMENT. text = only what replaces that passage, nothing around it.
    - replace_all: rewrite, start over, or change several places at once. text = the complete new document.
    - delete: remove a passage. find = exact passage (empty = the last paragraph). text = "".
    - none: nothing to write (only asides, or a question to you). text = "".

    Rules:
    - text is the document itself, never a report. Never write "Email draft created", "Here is", "Done".
    - ask spans are the job. Do what they say; never copy them into text.
    - words spans are the speaker's wording. Keep it, but drop spoken filler ("um", "like", "you know") and fix punctuation and capitalization.
    - If the speaker asks for a position ("before the sign-off", "after the first paragraph"), put the text exactly there.
    - gist spans are meaning. Express it in natural prose in the speaker's style.
    - aside and tone spans never appear in text. tone shapes the style.
    - "write an email/message" means the whole thing: greeting, short body, sign-off with the name from PROFILE.
    - Don't repeat text already in CURRENT_DOCUMENT. Don't invent facts the speaker didn't give.
    - Bullet points: "• " at the start of each line, one short idea per bullet (8–12 words). **bold** only when asked.
    - note: one short sentence to the speaker about what you did.

    Example 1
    CURRENT_DOCUMENT: (empty)
    SPANS:
    - ask: "let's write an email to Lena"
    - gist: "thanking her for connecting me with someone from Haven Founders"
    {"action":"append","find":"","text":"Hi Lena,\\n\\nThank you for connecting me with someone from Haven Founders. I really appreciate the introduction.\\n\\nBest,\\nSam","note":"Drafted the thank-you email."}

    Example 2
    CURRENT_DOCUMENT: Hi Lena,\\n\\nThanks for connecting me with someone from Haven Founders.\\n\\nBest,\\nSam
    SPANS:
    - ask: "make the thanks warmer"
    {"action":"replace","find":"Thanks for connecting me with someone from Haven Founders.","text":"Thank you so much for connecting me with someone from Haven Founders. It means a lot.","note":"Made the thanks warmer."}

    Example 3
    CURRENT_DOCUMENT: Some old draft about pricing.
    SPANS:
    - ask: "remove what's in the document and instead write"
    - gist: "a short note to Tomas that I'll call him tomorrow"
    {"action":"replace_all","find":"","text":"Hi Tomas,\\n\\nI'll give you a call tomorrow.\\n\\nBest,\\nSam","note":"Replaced the draft with a note to Tomas."}

    Example 4
    CURRENT_DOCUMENT: Hi Lena, ...
    SPANS:
    - aside: "okay this looks great"
    {"action":"none","find":"","text":"","note":"Nothing to change."}

    Return ONLY JSON with action, find, text, note.
    """

    static func actUserPrompt(
        utterance: String,
        document: String,
        revision: Int,
        context: ContextBundle,
        lastAssistant: String,
        recentUtterances: [String],
        spans: [SpeechSpan],
        forcedIntent: IntentKind?,
        retryHint: String?
    ) -> String {
        var parts: [String] = []
        parts.append("DOCUMENT_REVISION: \(revision)")
        parts.append("DOCUMENT_EMPTY: \(document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
        parts.append("PROFILE:\n\(truncate(context.profile, 2500))")
        parts.append("STYLE:\n\(truncate(context.style, 2000))")
        if !context.project.isEmpty {
            parts.append("PROJECT (\(context.projectName)):\n\(truncate(context.project, 3000))")
        }
        parts.append("CURRENT_DOCUMENT:\n\(document.isEmpty ? "(empty)" : document)")
        if !lastAssistant.isEmpty {
            parts.append("LAST_ASSISTANT_MESSAGE:\n\(lastAssistant)")
        }
        if !recentUtterances.isEmpty {
            parts.append("RECENT_UTTERANCES:\n" + recentUtterances.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        }
        parts.append("SPANS:\n" + spans.map { "- \($0.role.promptName): \"\($0.quote)\"" }.joined(separator: "\n"))
        if let forcedIntent {
            let rule: String
            switch forcedIntent {
            case .dictate: rule = "action must be append, text = the words spans exactly"
            case .discuss: rule = "action must be none"
            case .compose: rule = "action must be append"
            case .edit: rule = "action must be replace, replace_all, or delete"
            }
            parts.append("REQUIRED: \(rule).")
        }
        if let retryHint, !retryHint.isEmpty {
            parts.append("CORRECTION: \(retryHint)")
        }
        parts.append("UTTERANCE:\n\(utterance)")
        return parts.joined(separator: "\n\n")
    }

    static let labelSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "complete": ["type": "boolean"],
            "labels": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "i": ["type": "integer"],
                        "role": [
                            "type": "string",
                            "enum": ["aside", "ask", "gist", "words", "where", "tone"]
                        ],
                        "focus": ["type": ["string", "null"]]
                    ],
                    "required": ["i", "role"]
                ]
            ]
        ],
        "required": ["complete", "labels"]
    ]

    static let polishSystemPrompt = """
    Someone writes a document by voice. You get one PARAGRAPH from their DRAFT.

    kind:
    - leftover: the paragraph is a spoken instruction to the tool that ended up in the document by mistake ("just say with Haven Founders.", "delete the last part", "make it shorter"). It is not part of the message.
    - content: anything that is part of the message itself.

    clean: if content, the same paragraph with spoken filler removed ("like", "you know", "kind of", "sort of", "I mean", "so yeah", "um") and grammar fixed. Keep the meaning, the facts, and every point. Don't add anything. If it is already clean, return it unchanged. If leftover, "".

    Example: "Maybe like we will, you know, reach out if we find other ways how you could help."
    {"kind":"content","clean":"We'll reach out if we find other ways you could help."}

    Return ONLY JSON with kind and clean.
    """

    static let rewriteSystemPrompt = """
    You rewrite one PASSAGE of a draft, following the INSTRUCTION. The rest of the draft is there only for context.
    - Return only the new version of PASSAGE, as JSON {"text": "..."}.
    - Keep every point the passage makes, each one, even when making it shorter: cut filler and repetition, not points.
    - Don't add new points, thanks, or plans. Warmer, friendlier, more formal etc. change the wording, not the content.
    - Keep roughly the same number of sentences unless the instruction asks for longer or shorter.
    - If PASSAGE has a greeting or sign-off, keep them; if it doesn't, don't add one.
    - Keep paragraph breaks as blank lines.
    - Write in the speaker's style from PROFILE and STYLE.
    """

    static let rewriteSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string"]],
        "required": ["text"]
    ]

    static let polishSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "enum": ["content", "leftover"]],
            "clean": ["type": "string"]
        ],
        "required": ["kind", "clean"]
    ]

    static let writerSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["append", "replace", "replace_all", "delete", "none"]
            ],
            "find": ["type": "string"],
            "text": ["type": "string"],
            "note": ["type": "string"]
        ],
        "required": ["action", "find", "text", "note"]
    ]

    private static func truncate(_ s: String, _ max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "\n…"
    }
}

enum InterpreterError: LocalizedError {
    case ollamaUnreachable(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .ollamaUnreachable(let m), .badResponse(let m):
            return m
        }
    }
}
