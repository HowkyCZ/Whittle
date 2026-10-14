import Foundation

public struct DocumentParagraph: Equatable, Sendable {
    public var text: String
    /// UTF-16 range in the document, without the line terminator.
    public var range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }
}

/// Paragraphs as the panel numbers them. Same units the applier resolves "paragraph_N" against,
/// so ¶3 on screen is what "the third paragraph" edits.
public enum DocumentParagraphs {
    public static func split(_ document: String) -> [DocumentParagraph] {
        let ns = document as NSString
        var result: [DocumentParagraph] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { sub, range, _, _ in
            guard let sub, !sub.trimmingCharacters(in: .newlines).isEmpty else { return }
            result.append(DocumentParagraph(text: sub, range: range))
        }
        return result
    }

    /// The document with paragraph `index` replaced. Empty text removes the paragraph and the break after it.
    public static func replacing(_ index: Int, with text: String, in document: String) -> String {
        let paragraphs = split(document)
        guard paragraphs.indices.contains(index) else { return document }
        let ns = document as NSString
        let range = paragraphs[index].range
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return ns.replacingCharacters(in: range, with: trimmed)
        }

        func isNewline(_ i: Int) -> Bool {
            UnicodeScalar(ns.character(at: i)).map { CharacterSet.newlines.contains($0) } ?? false
        }
        var start = range.location
        var end = NSMaxRange(range)
        while end < ns.length, isNewline(end) { end += 1 }
        if end == ns.length {
            while start > 0, isNewline(start - 1) { start -= 1 }
        }
        return ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: "")
    }

    /// The document with its paragraphs in `order` (indices into `split`). A paragraph keeps its own break when its
    /// neighbour stays the same ("Best," then the name on the next line); new neighbours get a blank line between.
    public static func reordered(_ document: String, order: [Int]) -> String {
        let paragraphs = split(document)
        guard !paragraphs.isEmpty, order.sorted() == Array(paragraphs.indices) else { return document }
        let ns = document as NSString
        func gap(after i: Int) -> String {
            let start = NSMaxRange(paragraphs[i].range)
            let end = i + 1 < paragraphs.count ? paragraphs[i + 1].range.location : ns.length
            return ns.substring(with: NSRange(location: start, length: end - start))
        }
        var text = ns.substring(to: paragraphs[0].range.location)
        for (position, old) in order.enumerated() {
            text += paragraphs[old].text
            if position + 1 < order.count {
                text += order[position + 1] == old + 1 ? gap(after: old) : "\n\n"
            } else {
                text += old == paragraphs.count - 1 ? gap(after: old) : ""
            }
        }
        return text
    }

    public static func appending(_ text: String, to document: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return document }
        var base = document
        while let last = base.last, last.isWhitespace { base.removeLast() }
        return base.isEmpty ? trimmed : base + "\n\n" + trimmed
    }
}

public struct DiffRun: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case same, added, removed }
    /// Words of the run, single-space joined.
    public var text: String
    public var kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

public struct ParagraphChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case inserted
        case modified([DiffRun])
    }

    /// Index into the new document's paragraphs.
    public var index: Int
    public var kind: Kind

    public init(index: Int, kind: Kind) {
        self.index = index
        self.kind = kind
    }
}

/// What an edit did to the draft, paragraph by paragraph, for the inline diff.
public enum ParagraphDiff {
    /// Below this word overlap a changed paragraph reads as new text rather than as an edit.
    static let modifiedThreshold = 0.5

    public static func changes(before: String, after: String) -> [ParagraphChange] {
        let old = DocumentParagraphs.split(before).map(\.text)
        let new = DocumentParagraphs.split(after).map(\.text)
        var removed: [Int: String] = [:]
        var inserted: [Int] = []
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, let element, _): removed[offset] = element
            case .insert(let offset, _, _): inserted.append(offset)
            }
        }

        return inserted.sorted().map { index in
            let text = new[index]
            var best: (offset: Int, score: Double)?
            for offset in removed.keys.sorted() {
                let score = similarity(removed[offset]!, text)
                if score > (best?.score ?? 0) { best = (offset, score) }
            }
            if let best, best.score >= modifiedThreshold {
                let original = removed.removeValue(forKey: best.offset)!
                return ParagraphChange(index: index, kind: .modified(words(before: original, after: text)))
            }
            return ParagraphChange(index: index, kind: .inserted)
        }
    }

    /// Word-level diff. Removed words come before the words that replaced them.
    public static func words(before: String, after: String) -> [DiffRun] {
        let a = tokens(before)
        let b = tokens(after)
        var removedAt = Set<Int>()
        var insertedAt = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): insertedAt.insert(offset)
            }
        }

        var runs: [DiffRun] = []
        func push(_ word: String, _ kind: DiffRun.Kind) {
            if let last = runs.last, last.kind == kind {
                runs[runs.count - 1].text += " " + word
            } else {
                runs.append(DiffRun(text: word, kind: kind))
            }
        }
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, removedAt.contains(i) {
                push(a[i], .removed)
                i += 1
            } else if j < b.count, insertedAt.contains(j) {
                push(b[j], .added)
                j += 1
            } else if i < a.count, j < b.count {
                push(b[j], .same)
                i += 1
                j += 1
            } else {
                break
            }
        }
        return runs
    }

    /// The text a change added, as UTF-16 ranges in `after`: new paragraphs whole, reworded ones word by word.
    public static func addedRanges(before: String, after: String) -> [NSRange] {
        let paragraphs = DocumentParagraphs.split(after)
        var ranges: [NSRange] = []
        for change in changes(before: before, after: after) where paragraphs.indices.contains(change.index) {
            let paragraph = paragraphs[change.index]
            switch change.kind {
            case .inserted:
                ranges.append(paragraph.range)
            case .modified(let runs):
                let original = runs.filter { $0.kind != .added }.map(\.text).joined(separator: " ")
                ranges += addedWordRanges(before: original, after: paragraph.text)
                    .map { NSRange(location: $0.location + paragraph.range.location, length: $0.length) }
            }
        }
        return ranges
    }

    /// Ranges in `after` covering words that aren't in `before`; neighbouring words merge into one range.
    static func addedWordRanges(before: String, after: String) -> [NSRange] {
        let a = tokens(before)
        let words = tokenRanges(after)
        let b = words.map(\.text)
        var inserted: [Int] = []
        for change in b.difference(from: a) {
            if case .insert(let offset, _, _) = change { inserted.append(offset) }
        }
        var ranges: [NSRange] = []
        for offset in inserted.sorted() {
            let range = words[offset].range
            if let last = ranges.last, offset > 0, inserted.contains(offset - 1) {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    static func tokenRanges(_ text: String) -> [(text: String, range: NSRange)] {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range), $0.range)
        }
    }

    /// Share of words two paragraphs have in common, in order (Dice over the longest common subsequence).
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = tokens(lhs)
        let b = tokens(rhs)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        let removals = b.difference(from: a).removals.count
        let common = a.count - removals
        return 2 * Double(common) / Double(a.count + b.count)
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
