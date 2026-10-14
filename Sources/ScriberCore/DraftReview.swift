import Foundation

/// A recent spoken request the review pass checks the draft against.
public struct ReviewRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var utterance: String
    public var spans: [SpeechSpan]
    public var at: Date

    public init(id: UUID = UUID(), utterance: String, spans: [SpeechSpan], at: Date = Date()) {
        self.id = id
        self.utterance = utterance
        self.spans = spans
        self.at = at
    }
}

public struct ReviewFix: Equatable, Sendable {
    public var find: String
    public var replace: String
    public var why: String

    public init(find: String, replace: String, why: String = "") {
        self.find = find
        self.replace = replace
        self.why = why
    }
}

/// The model's verdict on one paragraph.
public struct ParagraphVerdict: Equatable, Sendable {
    public enum Kind: String, Sendable { case content, leftover }
    public var kind: Kind
    public var clean: String

    public init(kind: Kind, clean: String) {
        self.kind = kind
        self.clean = clean
    }
}

/// Structural checks that don't need a model.
public enum DocumentLint {
    public struct Report: Equatable, Sendable {
        public var hints: [String]
        public var fixes: [ReviewFix]
    }

    public static func check(_ document: String) -> Report {
        let paragraphs = paragraphs(document)
        var hints: [String] = []
        var fixes: [ReviewFix] = []

        for (a, b) in zip(paragraphs, paragraphs.dropFirst()) where normalize(a) == normalize(b) {
            hints.append("The paragraph \"\(a.prefix(60))\" appears twice in a row.")
            if document.contains(a + "\n\n" + b) {
                fixes.append(ReviewFix(find: a + "\n\n" + b, replace: a, why: "removed a repeated paragraph"))
            }
        }

        let greetings = paragraphs.indices.filter { isGreeting(paragraphs[$0]) }
        if greetings.count > 1 {
            hints.append("The greeting appears \(greetings.count) times; keep one at the top.")
            for g in greetings.dropFirst() where g > 0 && paragraphs[g].split(separator: "\n").count == 1 {
                let prev = paragraphs[g - 1]
                if normalize(prev) == normalize(paragraphs[g]) { continue }
                let pair = prev + "\n\n" + paragraphs[g]
                if document.contains(pair) {
                    fixes.append(ReviewFix(find: pair, replace: prev, why: "removed a repeated greeting"))
                }
            }
        } else if let g = greetings.first, g != 0 {
            hints.append("The greeting is not at the top.")
        }

        let signOffs = paragraphs.indices.filter { isSignOff(paragraphs[$0]) }
        if signOffs.count > 1 {
            hints.append("There are \(signOffs.count) sign-offs; keep one at the end.")
        }
        if let last = signOffs.last, last < paragraphs.count - 1 {
            hints.append("Text comes after the sign-off: \"\(paragraphs[last + 1].prefix(60))\".")
        }

        return Report(hints: hints, fixes: fixes)
    }

    /// Paragraphs that sit after the last sign-off, in order.
    public static func afterSignOff(_ document: String) -> (signOff: String, trailing: [String])? {
        let paragraphs = paragraphs(document)
        guard let last = paragraphs.indices.last(where: { isSignOff(paragraphs[$0]) }),
              last < paragraphs.count - 1 else { return nil }
        return (paragraphs[last], Array(paragraphs[(last + 1)...]))
    }

    public static func paragraphs(_ document: String) -> [String] {
        document
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func isGreeting(_ paragraph: String) -> Bool {
        let firstLine = paragraph.split(separator: "\n").first.map(String.init) ?? paragraph
        guard firstLine.count <= 40 else { return false }
        return firstLine.range(of: #"^(?i)(hi|hello|hey|dear)\b"#, options: .regularExpression) != nil
    }

    public static func isSignOff(_ paragraph: String) -> Bool {
        guard paragraph.count <= 60 else { return false }
        let pattern = #"^(?i)(best|cheers|thanks|many thanks|kind regards|regards|all the best|warmly|talk soon)\b[^\n]{0,20}(\n|$)"#
        return paragraph.range(of: pattern, options: .regularExpression) != nil
    }
}

public enum DraftReview {
    /// Requests older than this, or beyond the most recent few, count as settled.
    public static let window: TimeInterval = 5 * 60
    public static let maxRequests = 6

    public static func recent(_ requests: [ReviewRequest], now: Date = Date()) -> [ReviewRequest] {
        Array(requests.filter { now.timeIntervalSince($0.at) <= window }.suffix(maxRequests))
    }

    /// "Instead of X say Y" requests can be checked from their labels: X should be gone and Y present.
    /// A later request that touches the same text supersedes the earlier one.
    public static func unmetReplacements(document: String, requests: [ReviewRequest]) -> [ReviewFix] {
        var fixes: [ReviewFix] = []
        for (i, request) in requests.enumerated() {
            let targets = request.spans.filter { $0.role == .target }
            let payload = SpanPlanner.payloadText(from: request.spans)
            guard !targets.isEmpty, !payload.isEmpty else { continue }
            guard let found = SpanPlanner.firstTarget(in: document, from: targets) else { continue }
            if SpanPlanner.matchInDocument(payload, document: document) != nil { continue }
            if DocumentLint.normalize(payload).contains(DocumentLint.normalize(found)) { continue }
            let later = requests[(i + 1)...].flatMap(\.spans).filter { $0.role == .target || $0.role == .payload }
            if later.contains(where: { SpanPlanner.overlap($0.quote, found) >= 0.6 || SpanPlanner.overlap($0.quote, payload) >= 0.6 }) {
                continue
            }
            fixes.append(ReviewFix(find: found, replace: payload, why: "applied “\(payload.prefix(40))”"))
        }
        return fixes
    }

    /// The most recent request asked for specific wording that isn't in the draft.
    public static func latestMissingWords(document: String, requests: [ReviewRequest]) -> ReviewRequest? {
        guard let latest = requests.last else { return nil }
        let payload = SpanPlanner.payloadText(from: latest.spans)
        guard SpanPlanner.words(payload).count >= 3 else { return nil }
        return SpanPlanner.overlap(document, payload) < 0.5 ? latest : nil
    }

    /// Body paragraphs worth a polish pass: not greetings or sign-offs, and not already checked.
    public static func paragraphsToCheck(_ document: String, alreadyChecked: Set<String>) -> [String] {
        DocumentLint.paragraphs(document).filter { p in
            !DocumentLint.isGreeting(p) && !DocumentLint.isSignOff(p)
                && SpanPlanner.words(p).count >= 2
                && !alreadyChecked.contains(DocumentLint.normalize(p))
        }
    }

    /// A paragraph only counts as a leftover when it matches something said as an instruction or aside,
    /// and not something dictated as content. Dictated text always overlaps with speech, so overlap with
    /// the utterance alone proves nothing.
    public static func isSpokenLeftover(_ paragraph: String, requests: [ReviewRequest]) -> Bool {
        guard paragraph.split(whereSeparator: \.isWhitespace).count <= 20 else { return false }
        let spans = requests.flatMap(\.spans)
        let asked = spans.filter { $0.role == .instruction || $0.role == .meta }
        let dictated = spans.filter { $0.role == .payload || $0.role == .brief }
        let matchesAsk = asked.contains { SpanPlanner.overlap($0.quote, paragraph) >= 0.6 }
        let matchesContent = dictated.contains { SpanPlanner.overlap($0.quote, paragraph) >= 0.4 }
        return matchesAsk && !matchesContent
    }

    /// A polish may drop filler and fix grammar, not rewrite: most original words stay, few new ones appear.
    public static func acceptsPolish(original: String, clean: String) -> Bool {
        let a = SpanPlanner.words(original)
        let b = SpanPlanner.words(clean)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let kept = Double(a.intersection(b).count) / Double(a.count)
        let added = b.subtracting(a).count
        return kept >= 0.8 && added <= 2
    }

    public static func fix(for paragraph: String, verdict: ParagraphVerdict, requests: [ReviewRequest]) -> ReviewFix? {
        switch verdict.kind {
        case .leftover:
            guard isSpokenLeftover(paragraph, requests: requests) else { return nil }
            return ReviewFix(find: paragraph, replace: "", why: "removed a stray instruction")
        case .content:
            let clean = verdict.clean.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, DocumentLint.normalize(clean) != DocumentLint.normalize(paragraph),
                  acceptsPolish(original: paragraph, clean: clean) else { return nil }
            return ReviewFix(find: paragraph, replace: clean, why: "cleaned up spoken filler")
        }
    }

    /// Content left after the sign-off moves above it.
    public static func moveAboveSignOff(_ document: String) -> ReviewFix? {
        guard let (signOff, trailing) = DocumentLint.afterSignOff(document) else { return nil }
        let tail = ([signOff] + trailing).joined(separator: "\n\n")
        guard document.contains(tail) else { return nil }
        return ReviewFix(find: tail, replace: (trailing + [signOff]).joined(separator: "\n\n"), why: "moved text above the sign-off")
    }

    /// Turns fixes into ops, dropping any that can't be located, copy an instruction, or rewrite most of the draft.
    public static func ops(
        for fixes: [ReviewFix],
        document: String,
        requests: [ReviewRequest]
    ) -> (ops: [DocumentOp], applied: [ReviewFix], rejected: [String], result: String) {
        let asks = requests.flatMap { $0.spans.filter { $0.role == .instruction || $0.role == .meta } }
        var working = document
        var ops: [DocumentOp] = []
        var applied: [ReviewFix] = []
        var rejected: [String] = []
        var changed = 0

        for fix in fixes {
            let anchor: String
            if working.contains(fix.find) {
                anchor = fix.find
            } else if let match = SpanPlanner.matchInDocument(fix.find, document: working) {
                anchor = match
            } else {
                rejected.append("not found: \(fix.find.prefix(40))")
                continue
            }
            if anchor == fix.replace { continue }
            if !fix.replace.isEmpty, SpanPlanner.instructionOverlap(fix.replace, spans: asks) >= 0.55 {
                rejected.append("copies an instruction: \(fix.replace.prefix(40))")
                continue
            }
            let op = fix.replace.isEmpty
                ? DocumentOp(op: .delete, anchor: anchor)
                : DocumentOp(op: .replace, text: fix.replace, anchor: anchor)
            guard let next = try? DocumentModel.apply(op: op, to: working) else {
                rejected.append("could not apply: \(fix.find.prefix(40))")
                continue
            }
            if !fix.why.hasPrefix("moved") {
                changed += max(anchor.count, fix.replace.count)
            }
            working = next
            ops.append(op)
            applied.append(fix)
        }

        if !ops.isEmpty, changed > max(200, Int(Double(document.count) * 0.6)) {
            return ([], [], rejected + ["fixes would rewrite most of the draft"], document)
        }
        return (ops, applied, rejected, working)
    }
}
