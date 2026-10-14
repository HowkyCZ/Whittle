import Foundation

public struct SpanPlan: Equatable, Sendable {
    public var intent: IntentKind
    public var ops: [DocumentOp]
    public var assistantMessage: String?
    public var needsModelProse: Bool
    public var reason: String

    public init(
        intent: IntentKind,
        ops: [DocumentOp] = [],
        assistantMessage: String? = nil,
        needsModelProse: Bool,
        reason: String
    ) {
        self.intent = intent
        self.ops = ops
        self.assistantMessage = assistantMessage
        self.needsModelProse = needsModelProse
        self.reason = reason
    }
}

public struct ReconcileResult: Equatable, Sendable {
    public var response: InterpreterResponse
    public var note: String?
    public var copiedInstruction: Bool

    public init(response: InterpreterResponse, note: String? = nil, copiedInstruction: Bool = false) {
        self.response = response
        self.note = note
        self.copiedInstruction = copiedInstruction
    }
}

/// Turns labeled speech spans into document ops. The model labels clauses;
/// this layer decides whether we already know the edit or still need prose.
public enum SpanPlanner {
    public static func plan(
        spans: [SpeechSpan],
        utterance: String,
        document: String
    ) -> SpanPlan {
        let grouped = Dictionary(grouping: spans.filter { !$0.quote.isEmpty }, by: \.role)
        let meta = grouped[.meta] ?? []
        let targets = grouped[.target] ?? []
        let instructions = grouped[.instruction] ?? []
        let payloads = grouped[.payload] ?? []
        let briefs = grouped[.brief] ?? []
        let payloadText = join(payloads)
        let emptyDoc = document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let hasAction = !instructions.isEmpty || !payloads.isEmpty || !briefs.isEmpty
        if !hasAction {
            let note = meta.isEmpty
                ? "Nothing to do with the document"
                : "Aside — not a change to the document"
            return SpanPlan(intent: .discuss, assistantMessage: note, needsModelProse: false, reason: "spans-are-meta")
        }

        if let target = firstTarget(in: document, from: targets), !payloadText.isEmpty {
            return SpanPlan(
                intent: .edit,
                ops: [DocumentOp(op: .replace, text: payloadText, anchor: target)],
                needsModelProse: false,
                reason: "replace-from-spans"
            )
        }

        if let structural = firstStructuralTarget(targets), !payloadText.isEmpty {
            return SpanPlan(
                intent: .edit,
                ops: [DocumentOp(op: .replace, text: payloadText, target: structural)],
                needsModelProse: false,
                reason: "replace-structural-from-spans"
            )
        }

        if briefs.isEmpty && instructions.isEmpty && meta.isEmpty && !payloadText.isEmpty {
            return SpanPlan(
                intent: .dictate,
                ops: [DocumentOp(op: .append, text: payloadText)],
                needsModelProse: false,
                reason: "payload-only"
            )
        }

        if !payloadText.isEmpty, emptyDoc, briefs.isEmpty {
            // Instruction + wording: model should shape it (email, paragraph) from the payload.
            return SpanPlan(intent: .compose, needsModelProse: true, reason: "compose-from-payload")
        }

        if emptyDoc {
            return SpanPlan(intent: .compose, needsModelProse: true, reason: "compose-needed")
        }

        if !payloadText.isEmpty, firstTarget(in: document, from: targets) == nil {
            // New wording, no place marked in the current text → likely a new passage,
            // unless the instruction is clearly an in-place edit (model decides).
            return SpanPlan(intent: instructions.isEmpty ? .compose : .edit, needsModelProse: true, reason: "prose-or-edit")
        }

        return SpanPlan(
            intent: .edit,
            needsModelProse: true,
            reason: "edit-needed"
        )
    }

    public static func reconcile(
        response: InterpreterResponse,
        spans: [SpeechSpan],
        utterance: String,
        document: String,
        plan: SpanPlan
    ) -> ReconcileResult {
        var response = response
        response.spans = spans

        if plan.intent == .discuss && plan.ops.isEmpty && !plan.needsModelProse {
            response.intent = .discuss
            response.ops = []
            if response.assistantMessage == nil {
                response.assistantMessage = plan.assistantMessage
            }
            return ReconcileResult(response: response, note: plan.reason)
        }

        var notes: [String] = []
        var copiedInstruction = false
        var kept: [DocumentOp] = []

        for original in response.ops where original.op != .noDocumentChange {
            let op = normalizeAnchor(original, document: document)
            if let reason = rejectReason(op, document: document, spans: spans) {
                notes.append(reason)
                if reason.contains("instruction") || reason.contains("aside") {
                    copiedInstruction = true
                }
                continue
            }
            kept.append(repair(op, document: document, spans: spans))
        }

        if kept.isEmpty {
            let fallback = fallbackOps(spans: spans, document: document, plan: plan)
            if !fallback.isEmpty {
                kept = fallback
                notes.append("fell back to payload/target spans")
            }
        }

        if kept.isEmpty {
            response.intent = .discuss
            response.ops = []
            return ReconcileResult(
                response: response,
                note: notes.first ?? "No safe edit in the model output",
                copiedInstruction: copiedInstruction
            )
        }

        response.ops = kept
        if response.intent == .discuss {
            response.intent = plan.intent == .discuss ? .compose : plan.intent
        }
        return ReconcileResult(
            response: response,
            note: notes.isEmpty ? nil : notes.joined(separator: "; "),
            copiedInstruction: copiedInstruction
        )
    }

    public static func payloadText(from spans: [SpeechSpan]) -> String {
        join(spans.filter { $0.role == .payload })
    }

    public static func describe(_ spans: [SpeechSpan]) -> String {
        if spans.isEmpty { return "(none)" }
        return spans.map { "\($0.role.rawValue): \"\($0.quote.prefix(80))\"" }.joined(separator: " | ")
    }

    // MARK: - Internals

    /// Writers paraphrase anchors; snap them to the real document text, and turn edits on an empty document into appends.
    static func normalizeAnchor(_ op: DocumentOp, document: String) -> DocumentOp {
        var op = op
        let empty = document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty, op.op == .replace, let text = op.text {
            return DocumentOp(op: .append, text: text)
        }
        if let anchor = op.anchor, !anchor.isEmpty, !document.contains(anchor),
           let match = matchInDocument(anchor, document: document) {
            op.anchor = match
        }
        if restatesSurroundings(op, document: document), let text = op.text {
            return DocumentOp(op: .replace, text: text, target: "whole_document")
        }
        return op
    }

    /// A partial replace whose text also carries the draft's opening or closing is really a full rewrite;
    /// applying it in place would duplicate everything around the anchor.
    static func restatesSurroundings(_ op: DocumentOp, document: String) -> Bool {
        guard op.op == .replace, op.target != "whole_document", let text = op.text else { return false }
        let range: Range<String.Index>
        if let anchor = op.anchor, let r = document.range(of: anchor) {
            range = r
        } else if let target = op.target, let r = try? DocumentModel.resolveStructuralRange(target, in: document) {
            range = r
        } else {
            return false
        }
        if range == document.startIndex..<document.endIndex { return false }
        guard Double(text.count) >= Double(document.count) * 0.4 else { return false }
        var edges: [String] = []
        let before = String(document[..<range.lowerBound])
        if let cut = before.range(of: "\n\n") {
            edges.append(String(before[..<cut.lowerBound]))
        }
        let after = String(document[range.upperBound...])
        if let cut = after.range(of: "\n\n", options: .backwards) {
            edges.append(String(after[cut.upperBound...]))
        }
        let body = DocumentLint.normalize(text)
        return edges
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .contains { body.contains(DocumentLint.normalize($0)) }
    }

    static func firstTarget(in document: String, from spans: [SpeechSpan]) -> String? {
        let ordered = spans.sorted { $0.quote.count > $1.quote.count }
        for span in ordered {
            if let match = matchInDocument(span.quote, document: document) {
                return match
            }
        }
        return nil
    }

    static func matchInDocument(_ quote: String, document: String) -> String? {
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 4 else { return nil }
        if let range = document.range(of: q, options: .caseInsensitive) {
            return String(document[range])
        }
        if let exactWords = matchWordSequence(q, in: document) {
            return exactWords
        }
        return TextLocator.find(q, in: document)?.text
    }

    /// Spoken quotes often drop a word ("connecting with" vs "connecting me with").
    static func matchWordSequence(_ quote: String, in document: String) -> String? {
        let needles = tokens(quote)
        guard needles.count >= 3 else { return nil }
        let hay = tokensWithRanges(document)
        guard hay.count >= needles.count else { return nil }

        var i = 0
        while i < hay.count {
            guard hay[i].word == needles[0] else {
                i += 1
                continue
            }
            var n = 0
            var skipped = 0
            var lastMatch = i
            var j = i
            while j < hay.count && n < needles.count {
                if hay[j].word == needles[n] {
                    lastMatch = j
                    n += 1
                    skipped = 0
                } else {
                    skipped += 1
                    if skipped > 2 { break }
                }
                j += 1
            }
            if n == needles.count {
                return String(document[hay[i].range.lowerBound..<hay[lastMatch].range.upperBound])
            }
            i += 1
        }
        return nil
    }

    static func tokens(_ text: String) -> [String] {
        var words: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { substring, _, _, _ in
            if let substring { words.append(substring.lowercased()) }
        }
        return words
    }

    static func tokensWithRanges(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { substring, range, _, _ in
            if let substring { result.append((substring.lowercased(), range)) }
        }
        return result
    }

    static func firstStructuralTarget(_ spans: [SpeechSpan]) -> String? {
        let keys = [
            "first_paragraph": ["first paragraph", "opening", "the first paragraph", "first_paragraph"],
            "last_paragraph": ["last paragraph", "the last paragraph", "last_paragraph"],
            "last_sentence": ["last sentence", "the last sentence"],
            "whole_document": ["whole document", "the whole thing", "entire document"]
        ]
        for span in spans {
            let t = UtterancePolicy.collapse(span.quote)
            for (canonical, aliases) in keys where aliases.contains(where: { t.contains($0) }) {
                return canonical
            }
        }
        return nil
    }

    static func join(_ spans: [SpeechSpan]) -> String {
        spans.map(\.quote).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rejectReason(_ op: DocumentOp, document: String, spans: [SpeechSpan]) -> String? {
        switch op.op {
        case .append, .insert:
            guard let text = op.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "op missing text"
            }
            if OpSanitizer.isDuplicateAppend(text, document: document) {
                return "refused duplicate of existing text"
            }
            if instructionOverlap(text, spans: spans) >= 0.55 {
                return "op copied instruction/aside into the document"
            }
            return nil
        case .replace:
            guard let text = op.text else { return "op missing text" }
            if instructionOverlap(text, spans: spans) >= 0.55 {
                return "replace copied instruction/aside"
            }
            if isFragileReplace(op, document: document) {
                return "refused fragile replace of a tiny span"
            }
            if OpSanitizer.isDuplicateAppend(text, document: document) && op.target != "whole_document" {
                return "refused replace that reprints the document"
            }
            return nil
        default:
            return nil
        }
    }

    static func isFragileReplace(_ op: DocumentOp, document: String) -> Bool {
        if let target = op.target, isStructural(target) { return false }
        if let anchor = op.anchor {
            if anchor.count < 8 { return true }
            if document.range(of: anchor, options: .caseInsensitive) == nil { return true }
            return false
        }
        if let target = op.target {
            if isStructural(target) { return false }
            if target.count < 8 { return true }
            if document.range(of: target, options: .caseInsensitive) == nil { return true }
        }
        if op.start == nil && op.end == nil && op.anchor == nil && op.target == nil {
            return true
        }
        return false
    }

    static func isStructural(_ target: String) -> Bool {
        let key = target.lowercased().replacingOccurrences(of: " ", with: "_")
        return [
            "first_paragraph", "last_paragraph", "last_sentence",
            "whole_document", "document", "opening", "paragraph_1"
        ].contains(key) || key.hasPrefix("paragraph_")
    }

    static func repair(_ op: DocumentOp, document: String, spans: [SpeechSpan]) -> DocumentOp {
        var op = op
        if op.op == .append || op.op == .insert, let target = firstTarget(in: document, from: spans.filter { $0.role == .target }) {
            // Model appended the new wording; spans said where it belongs.
            if let text = op.text, !text.isEmpty {
                op = DocumentOp(op: .replace, text: text, anchor: target)
            }
        }
        return op
    }

    static func fallbackOps(spans: [SpeechSpan], document: String, plan: SpanPlan) -> [DocumentOp] {
        let payload = payloadText(from: spans)
        let targets = spans.filter { $0.role == .target }
        if let target = firstTarget(in: document, from: targets), !payload.isEmpty {
            return [DocumentOp(op: .replace, text: payload, anchor: target)]
        }
        if let structural = firstStructuralTarget(targets), !payload.isEmpty {
            return [DocumentOp(op: .replace, text: payload, target: structural)]
        }
        if !payload.isEmpty {
            return [DocumentOp(op: .append, text: payload)]
        }
        return []
    }

    static func instructionOverlap(_ text: String, spans: [SpeechSpan]) -> Double {
        let banned = spans.filter { $0.role == .instruction || $0.role == .meta }
        guard !banned.isEmpty else { return 0 }
        return banned.map { overlap(text, $0.quote) }.max() ?? 0
    }

    static func overlap(_ a: String, _ b: String) -> Double {
        let wa = words(a)
        let wb = words(b)
        guard !wb.isEmpty else { return 0 }
        if wb.count >= 4 {
            let collapsedA = UtterancePolicy.collapse(a)
            let collapsedB = UtterancePolicy.collapse(b)
            if collapsedB.count >= 16 && collapsedA.contains(collapsedB) { return 1 }
        }
        return Double(wa.intersection(wb).count) / Double(wb.count)
    }

    static func words(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "a", "an", "the", "to", "for", "with", "and", "or", "of", "in", "on",
            "it", "this", "that", "you", "i", "okay", "ok", "so", "just", "like"
        ]
        return Set(
            UtterancePolicy.collapse(text)
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .map(String.init)
                .filter { $0.count > 2 && !stop.contains($0) }
        )
    }
}
