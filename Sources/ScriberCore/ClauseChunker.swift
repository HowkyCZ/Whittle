import Foundation

public struct Clause: Equatable, Sendable {
    public var text: String
    /// UTF-16 range of `text` inside the utterance.
    public var location: Int
    public var length: Int

    public init(text: String, location: Int, length: Int) {
        self.text = text
        self.location = location
        self.length = length
    }
}

public struct ClauseLabel: Equatable, Sendable {
    public var index: Int
    public var role: SpanRole
    public var focus: String?

    public init(index: Int, role: SpanRole, focus: String? = nil) {
        self.index = index
        self.role = role
        self.focus = focus
    }
}

public struct ClauseLabeling: Equatable, Sendable {
    public var labels: [ClauseLabel]
    /// The model's read on whether the speaker finished the thought. Nil if it didn't say.
    public var complete: Bool?

    public init(labels: [ClauseLabel], complete: Bool?) {
        self.labels = labels
        self.complete = complete
    }
}

public struct LabelResult: Equatable, Sendable {
    public var spans: [SpeechSpan]
    public var complete: Bool

    public init(spans: [SpeechSpan], complete: Bool) {
        self.spans = spans
        self.complete = complete
    }
}

/// Splits an utterance into clauses before the model sees it, so the model
/// labels numbered pieces of what was actually said instead of inventing quotes.
public enum ClauseChunker {
    private static let punctuation = try! NSRegularExpression(pattern: #"[.!?;:,]+(?=\s|$)"#)
    private static let frames = try! NSRegularExpression(
        pattern: #"(?i)\b(instead of saying|instead of|rather than|you can just say|just say|saying|say|and then|but)\b"#
    )

    public static func clauses(_ utterance: String) -> [Clause] {
        let ns = utterance as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard ns.length > 0 else { return [] }

        var cuts: Set<Int> = [0, ns.length]
        for m in punctuation.matches(in: utterance, range: full) {
            cuts.insert(m.range.location + m.range.length)
        }
        for m in frames.matches(in: utterance, range: full) {
            cuts.insert(m.range.location)
        }

        let sorted = cuts.sorted()
        var result: [Clause] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b > a {
            let piece = ns.substring(with: NSRange(location: a, length: b - a))
            let leading = piece.prefix { $0.isWhitespace }.utf16.count
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if !trimmed.contains(where: { $0.isLetter || $0.isNumber }), var last = result.popLast() {
                // Stray punctuation belongs to the clause before it.
                let end = a + leading + trimmed.utf16.count
                last.length = end - last.location
                last.text = ns.substring(with: NSRange(location: last.location, length: last.length))
                result.append(last)
                continue
            }
            result.append(Clause(text: trimmed, location: a + leading, length: trimmed.utf16.count))
        }
        return result
    }
}

public enum SpanBuilder {
    private static let leadingFrame = try! NSRegularExpression(
        pattern: #"^(?i)((and|then|but|so)\s+)?(instead of saying|instead of|rather than|you can just say|just say|saying|say)\s+"#
    )

    /// Turns clause labels into ranged spans. A `focus` narrows a where/words clause
    /// to the text itself; the framing words around it ("say", "instead of saying") read as the ask.
    public static func spans(utterance: String, clauses: [Clause], labels: [ClauseLabel]) -> [SpeechSpan] {
        let ns = utterance as NSString
        let byIndex = Dictionary(realigned(labels, clauses: clauses).map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })

        var pieces: [SpeechSpan] = []
        for (offset, clause) in clauses.enumerated() {
            let label = byIndex[offset + 1]
            let role = label?.role ?? .instruction
            let clauseNS = clause.text as NSString

            var focus = label?.focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let narrows = role == .target || role == .payload || role == .brief
            if narrows {
                // The chunker cuts before framing verbs, so a where/words clause can start with one.
                let base = focus.isEmpty ? clause.text : focus
                let baseNS = base as NSString
                if let m = leadingFrame.firstMatch(in: base, range: NSRange(location: 0, length: baseNS.length)) {
                    focus = baseNS.substring(from: m.range.length)
                }
            }

            if !focus.isEmpty, narrows {
                let r = clauseNS.range(of: focus, options: .caseInsensitive)
                if r.location != NSNotFound, r.length < clauseNS.length {
                    let frameRole: SpanRole = .instruction
                    if r.location > 0 {
                        append(&pieces, ns: ns, start: clause.location, length: r.location, role: frameRole)
                    }
                    append(&pieces, ns: ns, start: clause.location + r.location, length: r.length, role: role)
                    let tail = clauseNS.length - (r.location + r.length)
                    if tail > 0 {
                        append(&pieces, ns: ns, start: clause.location + r.location + r.length, length: tail, role: frameRole)
                    }
                    continue
                }
            }
            append(&pieces, ns: ns, start: clause.location, length: clause.length, role: role)
        }
        return merged(pieces, ns: ns)
    }

    /// Small models sometimes number clauses off by one. A focus phrase says which clause the label
    /// really meant, so a label whose focus sits in another clause moves there.
    static func realigned(_ labels: [ClauseLabel], clauses: [Clause]) -> [ClauseLabel] {
        func contains(_ i: Int, _ focus: String) -> Bool {
            (1...clauses.count).contains(i) && clauses[i - 1].text.range(of: focus, options: .caseInsensitive) != nil
        }
        guard !clauses.isEmpty else { return labels }
        var placed: [Int: ClauseLabel] = [:]
        var moved = Set<Int>()
        for label in labels {
            guard let focus = label.focus, !focus.isEmpty, !contains(label.index, focus) else {
                if !moved.contains(label.index), placed[label.index] == nil { placed[label.index] = label }
                continue
            }
            let target = (1...clauses.count)
                .filter { contains($0, focus) && !moved.contains($0) }
                .min { abs($0 - label.index) < abs($1 - label.index) }
            if let target {
                placed[target] = ClauseLabel(index: target, role: label.role, focus: focus)
                moved.insert(target)
            } else if placed[label.index] == nil {
                placed[label.index] = ClauseLabel(index: label.index, role: label.role, focus: nil)
            }
        }
        return placed.values.sorted { $0.index < $1.index }
    }

    private static func append(_ out: inout [SpeechSpan], ns: NSString, start: Int, length: Int, role: SpanRole) {
        let raw = ns.substring(with: NSRange(location: start, length: length))
        let leading = raw.prefix { $0.isWhitespace }.utf16.count
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        out.append(SpeechSpan(role: role, quote: trimmed, location: start + leading, length: trimmed.utf16.count))
    }

    /// Adjacent spans with the same role become one, so "thank you, really appreciate it, cheers" stays one payload.
    private static func merged(_ spans: [SpeechSpan], ns: NSString) -> [SpeechSpan] {
        var out: [SpeechSpan] = []
        for span in spans {
            guard var last = out.last,
                  last.role == span.role,
                  let lastLoc = last.location, let lastLen = last.length,
                  let loc = span.location, let len = span.length else {
                out.append(span)
                continue
            }
            let gap = ns.substring(with: NSRange(location: lastLoc + lastLen, length: max(0, loc - lastLoc - lastLen)))
            guard gap.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) else {
                out.append(span)
                continue
            }
            let newLen = loc + len - lastLoc
            last.length = newLen
            last.quote = ns.substring(with: NSRange(location: lastLoc, length: newLen))
            out[out.count - 1] = last
        }
        return out
    }
}

public enum Completeness {
    private static let dangling: Set<String> = [
        "with", "from", "to", "for", "of", "the", "a", "an", "and", "or", "but",
        "saying", "that", "about", "my", "your", "his", "her", "their", "is", "are",
        "because", "like", "so", "than", "into", "at", "by", "on", "in"
    ]

    /// Speech that trails off mid-phrase ("…connecting me with") is waiting for its next fragment.
    public static func looksUnfinished(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last else { return false }
        if lastChar == "," || lastChar == "…" || trimmed.hasSuffix("...") { return true }
        let lastWord = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .last
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() } ?? ""
        return dangling.contains(lastWord)
    }
}
