import Foundation
import ScriberCore

/// What a Structure call is for.
enum OutlineTask: Equatable {
    /// The writer said something about the plan.
    case edit(speech: String)
    /// The draft changed: which paragraphs belong where, and which points they make.
    case check
    /// There's a draft and no plan yet: outline what's there.
    case derive
}

/// Structure and Review calls. Both use ChatGPT: their replies are small JSON, and the local model
/// is unreliable at references like "between the raise and the ask".
extension CodexEditor {
    // MARK: Structure

    func outline(_ task: OutlineTask, draft: String, outline: Outline, context: ContextBundle) async throws -> (OutlineReply, String) {
        var parts = Self.contextParts(context)
        parts.append("OUTLINE:\n\(outline.described())")
        parts.append("DRAFT:\n\(ParagraphEdits.numbered(draft))")
        switch task {
        case .edit(let speech):
            parts.append("TASK: edit\nSPEECH (just now):\n\(speech)")
        case .check:
            parts.append("TASK: check")
        case .derive:
            parts.append("TASK: derive")
        }
        let raw = try await json(kind: "structure", instructions: Self.structureInstructions, schema: OutlineReply.schema,
                                 prompt: parts.joined(separator: "\n\n"))
        guard let reply = OutlineReply.parse(raw) else { throw Failure.badReply(raw) }
        return (reply, raw)
    }

    static let structureInstructions = """
    You keep the outline of a piece of writing in Whittle's Structure mode. The writer plans by voice; you never write prose and never change the draft. You never run tools. You answer only with JSON matching the schema: the whole outline after this turn, the sections to write now, and a reply.

    THE OUTLINE
    - Sections in order. Each has an id, a title (1–5 words, sentence case), a why line, must-say points and the draft paragraphs written for it.
    - Keep the ids of existing sections and points exactly. Use "new" as the id of anything you add.
    - why: one sentence, only when the writer explained a section's purpose at length ("he doesn't know us yet, so ground it before asking anything"). Otherwise keep what's there, or "".
    - points: short (at most 8 words) things the section has to say, in the writer's terms ("I need to explain what Idea-to-Pilot is and frame it as Benelux" → "What Idea-to-Pilot is", "Frame it as Benelux").
    - paragraphs: ids of the DRAFT paragraphs ([p1], [p2]…) that are this section's text, [] if it isn't written. A paragraph belongs to one section at most; greetings and sign-offs belong to none.
    - covered: true only when the section's paragraphs actually say the point.

    TASK edit
    Do what SPEECH asks: add, remove, reorder, merge, split or rename sections, add, remove or reword points, set a why. "Between the raise and the ask" means after the section about the raise. When you reorder, keep each section's paragraphs with it. When you merge, the result keeps both sections' paragraphs and points. Change nothing that wasn't asked.
    write: ids of sections the writer asks to have written now ("write section three" → the third section; "write the rest" → every section with no paragraphs). [] otherwise.
    reply: "" unless the writer asked a question or you couldn't do something; then one or two plain sentences.

    TASK check
    The draft just changed. Keep sections, titles, why lines and points exactly as they are. Only update paragraphs and covered. write is [] and reply is "".

    TASK derive
    There's a draft and no outline. Outline the draft as it stands: one section per part of what it says, in order, each with the points it makes (covered true) and its paragraphs. write is [] and reply is "".
    """

    // MARK: Review

    func review(as agent: ReviewAgent, draft: String, context: ContextBundle) async throws -> AgentReview {
        var parts = Self.contextParts(context)
        parts.append("YOU: \(agent.name). \(agent.brief).")
        parts.append("DRAFT:\n\(draft)")
        let raw = try await json(kind: "review", instructions: Self.reviewInstructions, schema: AgentReview.schema,
                                 prompt: parts.joined(separator: "\n\n"))
        guard let review = AgentReview.parse(raw) else { throw Failure.badReply(raw) }
        return review
    }

    static let reviewInstructions = """
    You are one reviewer of a draft in Whittle's Review mode. YOU says who you are and what you look for; look only for that. You comment; you never rewrite the draft. You never run tools. You answer only with JSON matching the schema.

    - comments: usually one, at most two: what matters most for the draft working, within your brief. Other reviewers cover other angles, so stay in your lane. [] when nothing in your brief needs saying; never comment for the sake of it.
    - quote: the exact passage the comment is about, copied character for character from the DRAFT. A phrase or one sentence, never more.
    - comment: one or two short, plain sentences. Specific: say what's wrong and what would fix it. No praise, no hedging, no "consider".
    - The draft is written by the writer to its recipient. PROFILE is the writer; ON SCREEN is what they were looking at (often the message they're replying to); context files hold their facts and style.
    - Facts: something the context files don't mention isn't wrong. Flag what contradicts them, placeholders like [AMOUNT], and figures the files give differently.
    """

    func reply(as agent: ReviewAgent, to comment: ReviewComment, draft: String, context: ContextBundle) async throws -> AgentReply {
        var parts = Self.contextParts(context)
        parts.append("YOU: \(agent.name). \(agent.brief).")
        parts.append("DRAFT:\n\(draft)")
        parts.append("YOUR COMMENT on “\(comment.quote)”:\n\(comment.message)")
        let thread = comment.thread.map { ($0.from == .agent ? "You: " : "Writer: ") + $0.text }
        parts.append("CONVERSATION SINCE (oldest first):\n" + thread.joined(separator: "\n"))
        let raw = try await json(kind: "review-reply", instructions: Self.replyInstructions, schema: AgentReply.schema,
                                 prompt: parts.joined(separator: "\n\n"))
        guard let reply = AgentReply.parse(raw) else { throw Failure.badReply(raw) }
        return reply
    }

    static let replyInstructions = """
    You are a reviewer in Whittle's Review mode, talking with the writer about a comment you made on their draft. YOU says who you are. You never run tools. You answer only with JSON matching the schema.

    - reply: answer the writer's last message in one to three short, plain sentences. Change your mind when they give a good reason; hold your point when they don't, and say why.
    - conclusion: what the editor should change in the draft, given the whole conversation, as one direct instruction about the passage ("Say it's a second city, to be named once it's confirmed."). "" when the right outcome is to leave the draft as it is.
    """
}

/// What the window the writer came from is: shown above the draft so it's clear what the editor sees.
struct SourceSummary: Codable, Equatable {
    var headline: String
    var summary: String

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["headline", "summary"],
        "properties": ["headline": ["type": "string"], "summary": ["type": "string"]]
    ]
}

extension CodexEditor {
    func describeSource(app: String, title: String, text: String) async throws -> SourceSummary {
        let prompt = "APP: \(app)\nWINDOW TITLE: \(title)\n\nTEXT (OCR of the window):\n\(text.prefix(6000))"
        let raw = try await json(kind: "source", instructions: Self.sourceInstructions, schema: SourceSummary.schema, prompt: prompt,
                                 model: fastModel)
        guard let json = InterpreterJSON.extractJSONObject(raw), let data = json.data(using: .utf8),
              let summary = try? JSONDecoder().decode(SourceSummary.self, from: data) else { throw Failure.badReply(raw) }
        return summary
    }

    static let sourceInstructions = """
    The writer opened Whittle, a voice writing tool, from another app. You get the text read (by OCR) from that window. Say what it is, so the writer can see what the editor will take into account. You never run tools. You answer only with JSON matching the schema.

    - headline: what the window shows, at most 8 words, sentence case: "Email from Tomas · Re: yesterday", "LinkedIn post by Jo Park", "Google Doc · Q3 plan", "Chat with Claude". Use names and subjects from the text.
    - summary: one plain sentence, at most 25 words, on what it's about or asks, from the writer's side ("Tomas asks whether the program could run beyond Rotterdam."). Ignore menus, buttons, sidebars and unrelated text. If there's nothing meaningful, say what the window is.
    """
}
