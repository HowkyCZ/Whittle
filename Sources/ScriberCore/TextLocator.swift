import Foundation

/// Finds the passage a spoken reference points at. Speech arrives through Whisper, so words can be
/// misheard ("heaven founders" for "Haven Founders") or dropped; matching is per word, tolerant of
/// spelling and sound-alike differences, and allows small gaps.
public enum TextLocator {
    public struct Match: Equatable, Sendable {
        public var range: Range<String.Index>
        public var text: String
        public var score: Double
    }

    /// Below this, a fuzzy match is more likely a different passage than a mishearing.
    static let minimumScore = 0.62

    public static func find(_ reference: String, in document: String) -> Match? {
        let query = strippedReference(reference)
        guard !query.isEmpty, !document.isEmpty else { return nil }
        let vague: Set<String> = ["it", "that", "this", "those", "these", "them", "there", "the", "a", "part", "bit", "thing"]
        if tokens(query).allSatisfy({ vague.contains($0.word) }) { return nil }

        if let structural = structuralRange(query, in: document) {
            return Match(range: structural, text: String(document[structural]), score: 1)
        }

        var aboutTopic = false
        var needle = query
        if let topic = topicPhrase(query) {
            needle = topic
            aboutTopic = true
        }

        guard let match = align(needle, in: document) else { return nil }
        if aboutTopic {
            let sentence = sentenceRange(containing: match.range, in: document)
            return Match(range: sentence, text: String(document[sentence]), score: match.score)
        }
        return match
    }

    // MARK: - Spoken references

    /// "the part where it says X" → "X"; leading articles and quote words don't need to match.
    static func strippedReference(_ reference: String) -> String {
        var q = reference.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let leading = #"^(?i)(where (it|you) (says?|said|wrote|write)|the (bit|part|line|sentence) (where|that says|saying)|it says|you say|you said|you wrote|saying|say)\s+"#
        while let r = q.range(of: leading, options: .regularExpression) {
            q.removeSubrange(r)
        }
        return q.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// "the part about pricing", "the sentence about the deck" → "pricing", "the deck".
    static func topicPhrase(_ query: String) -> String? {
        let pattern = #"^(?i)(the\s+)?(part|bit|sentence|line|paragraph|section|thing)\s+(about|on|regarding|with)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let r = Range(m.range(at: 4), in: query) else { return nil }
        return String(query[r])
    }

    static func structuralRange(_ query: String, in document: String) -> Range<String.Index>? {
        let q = query.lowercased()
            .replacingOccurrences(of: #"^(the|this|that|my)\s+"#, with: "", options: .regularExpression)
        let paragraphs = visibleParagraphs(in: document)
        func range(_ r: Range<String.Index>) -> Range<String.Index>? { r }

        switch q {
        case "whole thing", "whole document", "whole email", "whole draft", "entire thing", "entire email",
             "entire document", "everything", "email", "draft", "document":
            return document.startIndex..<document.endIndex
        case "greeting", "salutation":
            return paragraphs.first.flatMap(range)
        case "sign off", "sign-off", "signoff", "signature", "closing":
            return blocks(in: document).last
        case "last sentence":
            return try? DocumentModel.resolveStructuralRange("last_sentence", in: document)
        case "first sentence":
            return firstSentence(in: document)
        default:
            break
        }

        if let numbers = CommandParser.paragraphNumbers(q), numbers.count == 1 {
            let index = numbers[0] == -1 ? paragraphs.count - 1 : numbers[0] - 1
            return paragraphs.indices.contains(index) ? paragraphs[index] : nil
        }
        return nil
    }

    /// Paragraphs as numbered in the margin (¶1, ¶2…): every non-empty line.
    public static func visibleParagraphs(in document: String) -> [Range<String.Index>] {
        DocumentParagraphs.split(document).compactMap { Range($0.range, in: document) }
    }

    /// Paragraphs as the reader sees them: separated by blank lines, so "Best,\nSam" is one.
    public static func blocks(in document: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = document.startIndex
        let breaks = (try? NSRegularExpression(pattern: #"\n[ \t]*\n\s*"#))?
            .matches(in: document, range: NSRange(document.startIndex..., in: document))
            .compactMap { Range($0.range, in: document) } ?? []
        for gap in breaks + [document.endIndex..<document.endIndex] {
            var lower = start, upper = gap.lowerBound
            while lower < upper, document[lower].isWhitespace { lower = document.index(after: lower) }
            while upper > lower, document[document.index(before: upper)].isWhitespace { upper = document.index(before: upper) }
            if lower < upper { result.append(lower..<upper) }
            start = gap.upperBound
        }
        return result
    }

    static func firstSentence(in document: String) -> Range<String.Index>? {
        guard let start = document.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let end = document[start...].firstIndex(where: { ".!?\n".contains($0) }).map { document.index(after: $0) } ?? document.endIndex
        return start..<end
    }

    public static func sentenceRange(containing range: Range<String.Index>, in document: String) -> Range<String.Index> {
        let enders: Set<Character> = [".", "!", "?", "\n"]
        var start = range.lowerBound
        while start > document.startIndex {
            let prev = document.index(before: start)
            if enders.contains(document[prev]) { break }
            start = prev
        }
        while start < range.lowerBound, document[start].isWhitespace { start = document.index(after: start) }
        var end = range.upperBound
        while end < document.endIndex, !enders.contains(document[end]) { end = document.index(after: end) }
        if end < document.endIndex, document[end] != "\n" { end = document.index(after: end) }
        return start..<end
    }

    // MARK: - Fuzzy alignment

    struct Token {
        var word: String
        var range: Range<String.Index>
    }

    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { sub, range, _, _ in
            if let sub { out.append(Token(word: sub.lowercased(), range: range)) }
        }
        return out
    }

    /// Local alignment of the reference words against the document words (Smith–Waterman over words).
    static func align(_ query: String, in document: String) -> Match? {
        let q = tokens(query).map(\.word)
        let d = tokens(document)
        guard !q.isEmpty, !d.isEmpty else { return nil }

        let gap = -0.45
        let mismatch = -0.6
        let rows = q.count + 1
        let cols = d.count + 1
        var score = [[Double]](repeating: [Double](repeating: 0, count: cols), count: rows)
        var start = [[Int]](repeating: [Int](repeating: 0, count: cols), count: rows)
        var best = (value: 0.0, i: 0, j: 0)

        for i in 1..<rows {
            for j in 1..<cols {
                let sim = similarity(q[i - 1], d[j - 1].word)
                let diag = score[i - 1][j - 1] + (sim > 0 ? sim : mismatch)
                let up = score[i - 1][j] + gap
                let left = score[i][j - 1] + gap
                var value = max(0, diag, up, left)
                var origin = j
                if value == 0 {
                    value = 0
                } else if value == diag {
                    origin = score[i - 1][j - 1] == 0 ? j : start[i - 1][j - 1]
                } else if value == up {
                    origin = score[i - 1][j] == 0 ? j : start[i - 1][j]
                } else {
                    origin = score[i][j - 1] == 0 ? j : start[i][j - 1]
                }
                score[i][j] = value
                start[i][j] = origin
                if value > best.value { best = (value, i, j) }
            }
        }

        let normalized = best.value / Double(q.count)
        guard normalized >= minimumScore, best.j > 0 else { return nil }
        let first = d[max(start[best.i][best.j], 1) - 1]
        let last = d[best.j - 1]
        let range = first.range.lowerBound..<last.range.upperBound
        return Match(range: range, text: String(document[range]), score: normalized)
    }

    /// 1 for the same word, partial credit for likely mishearings, 0 otherwise.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let shorter = min(a.count, b.count)
        guard shorter >= 3 else { return 0 }
        let ratio = 1 - Double(levenshtein(a, b)) / Double(max(a.count, b.count))
        if ratio >= 0.74 { return 0.85 }
        if soundex(a) == soundex(b), ratio >= 0.5 { return 0.75 }
        return 0
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    static func soundex(_ word: String) -> String {
        let codes: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6"
        ]
        let letters = word.lowercased().filter(\.isLetter)
        guard let first = letters.first else { return "" }
        var out = String(first)
        var last = codes[first]
        for ch in letters.dropFirst() {
            let code = codes[ch]
            if let code, code != last { out.append(code) }
            if !"hw".contains(ch) { last = code }
            if out.count == 4 { break }
        }
        return out.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    // MARK: - Names

    /// Capitalized words and phrases that aren't sentence starts: names the speaker will say again.
    public static func names(in document: String) -> [String] {
        let pattern = #"(?<=[a-z,;:] |[a-z,;:]  )([A-Z][\w'’-]+(?:\s+[A-Z][\w'’-]+)*)|^(?:Hi|Hello|Hey|Dear)\s+([A-Z][\w'’-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        var seen: [String] = []
        for m in regex.matches(in: document, range: NSRange(document.startIndex..., in: document)) {
            for group in 1...2 {
                if let r = Range(m.range(at: group), in: document) {
                    let name = String(document[r])
                    if !seen.contains(name), name.count >= 3, name != "I" { seen.append(name) }
                }
            }
        }
        return seen
    }

    /// Respells misheard names in spoken text using how the document writes them ("heaven founders" → "Haven Founders").
    public static func respellNames(_ text: String, using document: String) -> String {
        var result = text
        for name in names(in: document) {
            let nameWords = tokens(name).map(\.word)
            guard !nameWords.isEmpty else { continue }
            let words = tokens(result)
            guard words.count >= nameWords.count else { continue }
            for i in stride(from: words.count - nameWords.count, through: 0, by: -1) {
                let window = words[i..<(i + nameWords.count)]
                let sims = zip(window, nameWords).map { similarity($0.word, $1) }
                guard sims.allSatisfy({ $0 > 0 }) else { continue }
                let r = window.first!.range.lowerBound..<window.last!.range.upperBound
                if result[r] != name { result.replaceSubrange(r, with: name) }
                break
            }
        }
        return result
    }
}
