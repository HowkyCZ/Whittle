import Foundation
import NaturalLanguage

/// A place in the draft named by position: "paragraph two", "the second sentence of paragraph three",
/// "the last sentence", "this" (the selection), "the greeting", "the sign-off".
public enum DraftPlace: Equatable, Sendable {
    /// 1-based; negative counts from the end (-1 is the last).
    case paragraph(Int)
    /// Same numbering; without a paragraph it counts across the draft.
    case sentence(Int, paragraph: Int?)
    case selection
    /// The paragraph or sentence the selection is in.
    case currentParagraph
    case currentSentence
    case greeting
    case signOff
}

/// An edit that needs no model: it moves, removes or adds exactly what was said.
public enum MechanicalEdit: Equatable, Sendable {
    case move(paragraph: Int, to: Int, after: Bool)
    case moveToEdge(paragraph: Int, top: Bool)
    case swap(Int, Int)
    case delete(DraftPlace)
    case merge(Int, Int)
    case split(paragraph: Int, afterSentence: Int)
    case replaceExactly(DraftPlace, text: String)
    /// Without a place: at the end of the draft (`after`) or the top.
    case insertExactly(text: String, place: DraftPlace?, after: Bool)
    case bold(DraftPlace?, phrase: String?)
    /// The paragraph's sentences as bullets, word for word.
    case list(paragraph: Int)

    public var summary: String {
        switch self {
        case .move(let p, let to, let after): return "Moved ¶\(p) \(after ? "after" : "before") ¶\(to)"
        case .moveToEdge(let p, let top): return "Moved ¶\(p) to the \(top ? "top" : "end")"
        case .swap(let a, let b): return "Swapped ¶\(a) and ¶\(b)"
        case .delete: return "Deleted"
        case .merge(let a, let b): return "Merged ¶\(a) and ¶\(b)"
        case .split(let p, let s): return "Split ¶\(p) after sentence \(s)"
        case .replaceExactly: return "Replaced word for word"
        case .insertExactly: return "Added word for word"
        case .bold: return "Made bold"
        case .list(let p): return "Made ¶\(p) a list"
        }
    }
}

/// What a spoken position and an exact edit mean, decided by rules in well under a millisecond. Anything these
/// don't cover goes to the editor model as before; when they find a place, the model is told where it is.
public enum SpokenMechanics {
    // MARK: Words

    static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "last": -1, "final": -1, "penultimate": -2,
        "second to last": -2, "second last": -2,
    ]
    static let cardinalWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    ]
    static let ord = #"second to last|second last|penultimate|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|last|final|\d+(?:st|nd|rd|th)"#
    static let num = #"one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|\d+"#
    static let para = #"(?:paragraph|para)"#

    static func number(_ word: String?) -> Int? {
        guard let w = word?.lowercased().trimmingCharacters(in: .whitespaces), !w.isEmpty else { return nil }
        if let n = ordinalWords[w] ?? cardinalWords[w] { return n }
        let digits = w.prefix { $0.isNumber }
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: Places

    static let sentencePattern = #"(?:the\s+)?(?:("# + ord + #")\s+sentence|sentence\s+(?:number\s+)?("# + num + #"))(?:\s+(?:of|in|from)\s+(?:the\s+)?(?:("# + ord + #")\s+"# + para + #"|"# + para + #"\s+(?:number\s+)?("# + num + #")))?"#
    static let paragraphPattern = #"(?:the\s+)?(?:("# + ord + #")\s+"# + para + #"|"# + para + #"\s+(?:number\s+)?("# + num + #"))"#
    static let namedPattern = #"(?:the\s+)?(greeting|salutation|opening line|sign[- ]?off|signature|closing)"#
    static let currentPattern = #"this\s+(paragraph|sentence)|the\s+(?:selection|selected text|highlighted text)|what i (?:selected|highlighted)"#

    /// A whole phrase read as a place, or nil.
    public static func place(_ phrase: String) -> DraftPlace? {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.:;")))
        if let g = groups(sentencePattern, p, whole: true) {
            guard let index = number(g[0]) ?? number(g[1]) else { return nil }
            return .sentence(index, paragraph: number(g[2]) ?? number(g[3]))
        }
        if let g = groups(paragraphPattern, p, whole: true) {
            return (number(g[0]) ?? number(g[1])).map { .paragraph($0) }
        }
        if let g = groups(namedPattern, p, whole: true), let name = g[0]?.lowercased() {
            return name.contains("sign") || name == "closing" ? .signOff : .greeting
        }
        if let g = groups(currentPattern, p, whole: true) {
            if let unit = g[0]?.lowercased() { return unit == "paragraph" ? .currentParagraph : .currentSentence }
            return .selection
        }
        if ["this", "that", "it", "this part", "that part", "this bit", "that bit"].contains(p.lowercased()) { return .selection }
        return nil
    }

    /// Places named anywhere in what was said, with where they were said (UTF-16), in order.
    public static func places(in utterance: String) -> [(place: DraftPlace, spoken: NSRange)] {
        let ns = utterance as NSString
        var found: [(DraftPlace, NSRange)] = []
        var taken = IndexSet()
        for pattern in [sentencePattern, paragraphPattern, namedPattern, currentPattern] {
            guard let regex = try? NSRegularExpression(pattern: #"\b(?:"# + pattern + #")\b"#, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: utterance, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range
                guard !taken.intersects(integersIn: range.location..<NSMaxRange(range)),
                      let place = place(ns.substring(with: range)) else { continue }
                taken.insert(integersIn: range.location..<NSMaxRange(range))
                found.append((place, range))
            }
        }
        return found.sorted { $0.1.location < $1.1.location }
    }

    // MARK: Edits

    /// Fillers before the command ("okay so", "um, can you").
    static let lead = CommandParser.lead

    /// The whole utterance as an edit that needs no model, or nil.
    public static func edit(in utterance: String) -> MechanicalEdit? {
        parse(utterance)?.edit
    }

    struct Parsed {
        var edit: MechanicalEdit
        /// UTF-16 ranges in the utterance: what was pointed at, and the exact words.
        var targets: [NSRange]
        var exact: NSRange?
        /// Where the command itself starts (after fillers).
        var start: Int
    }

    static func parse(_ utterance: String) -> Parsed? {
        let ns = utterance as NSString
        var start = 0
        if let leadRegex = try? NSRegularExpression(pattern: lead),
           let m = leadRegex.firstMatch(in: utterance, range: NSRange(location: 0, length: ns.length)) {
            start = NSMaxRange(m.range)
        }
        let body = ns.substring(from: start)
        let bodyNS = body as NSString
        func range(_ r: NSRange) -> NSRange { NSRange(location: r.location + start, length: r.length) }
        let end = #"\s*[.!]?$"#
        let exactCue = #"(?:exactly|word for word|verbatim)[:,]?\s+"#

        func match(_ pattern: String) -> NSTextCheckingResult? {
            guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")", options: [.caseInsensitive]) else { return nil }
            return regex.firstMatch(in: body, range: NSRange(location: 0, length: bodyNS.length))
        }
        func text(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : bodyNS.substring(with: r)
        }

        // "replace the second sentence with exactly …" / "change paragraph two to word for word …"
        if let m = match(#"(?:replace|change)\s+(.+?)\s+(?:with|to|into)\s+"# + exactCue + #"(.+)$"#),
           let where_ = text(m, 1).flatMap(place), let words = text(m, 2).flatMap(exactText) {
            return Parsed(edit: .replaceExactly(where_, text: words), targets: [range(m.range(at: 1))], exact: range(m.range(at: 2)), start: start)
        }
        // "after paragraph two, say exactly …" / "at the end, add word for word …"
        if let m = match(#"(?:(?:and\s+)?(after|before)\s+(.+?)|(at the end|at the bottom|at the top|at the start|at the beginning))[,:]?\s+(?:say|write|add|put|insert)(?:\s+a(?:\s+new)?\s+(?:paragraph|sentence|line)(?:\s+(?:saying|that says))?)?\s+"# + exactCue + #"(.+)$"#),
           let words = text(m, 4).flatMap(exactText) {
            if let edge = text(m, 3)?.lowercased() {
                let top = edge.contains("top") || edge.contains("start") || edge.contains("beginning")
                return Parsed(edit: .insertExactly(text: words, place: nil, after: !top), targets: [], exact: range(m.range(at: 4)), start: start)
            }
            if let side = text(m, 1)?.lowercased(), let where_ = text(m, 2).flatMap(place) {
                return Parsed(edit: .insertExactly(text: words, place: where_, after: side == "after"), targets: [range(m.range(at: 2))],
                              exact: range(m.range(at: 4)), start: start)
            }
        }
        // "move paragraph one before paragraph three"
        if let m = match(#"(?:move|put|shift)\s+(.+?)\s+(?:to\s+)?(?:go\s+)?(before|after|above|below|ahead of|in front of|behind)\s+(.+?)"# + end),
           case .paragraph(let a)? = text(m, 1).flatMap(place), case .paragraph(let b)? = text(m, 3).flatMap(place) {
            let side = text(m, 2)?.lowercased() ?? ""
            let after = ["after", "below", "behind"].contains(side)
            return Parsed(edit: .move(paragraph: a, to: b, after: after), targets: [range(m.range(at: 1)), range(m.range(at: 3))], exact: nil, start: start)
        }
        // "move paragraph two to the end"
        if let m = match(#"(?:move|put|shift)\s+(.+?)\s+to\s+the\s+(end|bottom|top|start|beginning)(?:\s+of the (?:draft|email|note|text|message))?"# + end),
           case .paragraph(let a)? = text(m, 1).flatMap(place) {
            let edge = text(m, 2)?.lowercased() ?? ""
            return Parsed(edit: .moveToEdge(paragraph: a, top: ["top", "start", "beginning"].contains(edge)), targets: [range(m.range(at: 1))], exact: nil, start: start)
        }
        // "swap paragraphs one and three" / "swap paragraph one with paragraph three"
        if let m = match(#"swap\s+(?:"# + para + #"s\s+("# + num + #")\s+and\s+("# + num + #")|(.+?)\s+(?:and|with)\s+(.+?))"# + end) {
            if let a = number(text(m, 1)), let b = number(text(m, 2)) {
                return Parsed(edit: .swap(a, b), targets: [range(m.range(at: 1)), range(m.range(at: 2))], exact: nil, start: start)
            }
            if case .paragraph(let a)? = text(m, 3).flatMap(place), case .paragraph(let b)? = text(m, 4).flatMap(place) {
                return Parsed(edit: .swap(a, b), targets: [range(m.range(at: 3)), range(m.range(at: 4))], exact: nil, start: start)
            }
        }
        // "merge paragraphs two and three" / "join paragraph two with the next one"
        if let m = match(#"(?:merge|join|combine)\s+(?:"# + para + #"s\s+("# + num + #")\s+and\s+("# + num + #")|(.+?)\s+(?:and|with|into)\s+(.+?))"# + end) {
            if let a = number(text(m, 1)), let b = number(text(m, 2)) {
                return Parsed(edit: .merge(a, b), targets: [range(m.range(at: 1)), range(m.range(at: 2))], exact: nil, start: start)
            }
            if case .paragraph(let a)? = text(m, 3).flatMap(place) {
                let other = text(m, 4)?.lowercased() ?? ""
                if other.contains("next") || other.contains("one after") || other.contains("following") {
                    return Parsed(edit: .merge(a, a + 1), targets: [range(m.range(at: 3))], exact: nil, start: start)
                }
                if other.contains("previous") || other.contains("one before") {
                    return Parsed(edit: .merge(a - 1, a), targets: [range(m.range(at: 3))], exact: nil, start: start)
                }
                if case .paragraph(let b)? = place(other) {
                    return Parsed(edit: .merge(a, b), targets: [range(m.range(at: 3)), range(m.range(at: 4))], exact: nil, start: start)
                }
            }
        }
        // "split paragraph two after the first sentence"
        if let m = match(#"split\s+(.+?)\s+after\s+(?:the\s+)?("# + ord + #")\s+sentence"# + end),
           case .paragraph(let p)? = text(m, 1).flatMap(place), let s = number(text(m, 2)) {
            return Parsed(edit: .split(paragraph: p, afterSentence: s), targets: [range(m.range(at: 1))], exact: nil, start: start)
        }
        // "make paragraph three a list" (word for word; "bullet points" asks the editor to condense)
        if let m = match(#"(?:make|turn)\s+(.+?)\s+(?:into\s+)?(?:a\s+)?(?:list|bulleted list|bullet list)"# + end),
           case .paragraph(let p)? = text(m, 1).flatMap(place) {
            return Parsed(edit: .list(paragraph: p), targets: [range(m.range(at: 1))], exact: nil, start: start)
        }
        // "make the last sentence bold" / "bold eight weeks"
        if let m = match(#"(?:(?:make|put|set)\s+(.+?)\s+(?:in\s+)?bold|bold\s+(.+?))"# + end) {
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let phrase = bodyNS.substring(with: r).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’ ,."))
            guard !phrase.isEmpty else { return nil }
            if let where_ = place(phrase) {
                return Parsed(edit: .bold(where_, phrase: nil), targets: [range(r)], exact: nil, start: start)
            }
            return Parsed(edit: .bold(nil, phrase: phrase), targets: [range(r)], exact: nil, start: start)
        }
        // "delete the last sentence" / "remove paragraph four"
        if let m = match(#"(?:delete|remove|cut|drop|get rid of)\s+(.+?)"# + end),
           let where_ = text(m, 1).flatMap(place) {
            return Parsed(edit: .delete(where_), targets: [range(m.range(at: 1))], exact: nil, start: start)
        }
        return nil
    }

    /// The words after "exactly", up to "end quote" if it's said. Nil when more instructions follow the quote.
    static func exactText(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"[,.]?\s*\b(?:end quote|unquote|close quote|end of quote)\b[.,!]?"#, options: [.regularExpression, .caseInsensitive]) {
            let after = t[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard after.isEmpty else { return nil }
            t = String(t[..<r.lowerBound])
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’:,").union(.whitespaces))
        return t.isEmpty ? nil : t
    }

    // MARK: The draft

    /// Sentence ranges (UTF-16, trailing spaces left out) inside `range` of `text`.
    public static func sentences(in text: String, range: NSRange) -> [NSRange] {
        let ns = text as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length, let swiftRange = Range(range, in: text) else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [NSRange] = []
        tokenizer.enumerateTokens(in: swiftRange) { r, _ in
            var n = NSRange(r, in: text)
            while n.length > 0, let c = UnicodeScalar(ns.character(at: NSMaxRange(n) - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(c) { n.length -= 1 }
            if n.length > 0 { result.append(n) }
            return true
        }
        return result
    }

    static func pick<T>(_ items: [T], _ n: Int) -> T? {
        let i = n > 0 ? n - 1 : items.count + n
        return items.indices.contains(i) ? items[i] : nil
    }

    /// Where a place is in the draft (UTF-16), or nil when it isn't there.
    public static func range(of place: DraftPlace, in draft: String, selection: NSRange?) -> NSRange? {
        let paragraphs = DocumentParagraphs.split(draft)
        let selected = selection.flatMap { $0.length > 0 ? $0 : nil }
        func paragraph(containing location: Int) -> DocumentParagraph? {
            paragraphs.first { NSLocationInRange(location, $0.range) || NSMaxRange($0.range) == location }
        }
        switch place {
        case .paragraph(let n):
            return pick(paragraphs, n)?.range
        case .sentence(let n, let p):
            if let p {
                guard let paragraph = pick(paragraphs, p) else { return nil }
                return pick(sentences(in: draft, range: paragraph.range), n)
            }
            let all = paragraphs.flatMap { sentences(in: draft, range: $0.range) }
            return pick(all, n)
        case .selection:
            return selected
        case .currentParagraph:
            return selection.flatMap { paragraph(containing: $0.location)?.range }
        case .currentSentence:
            guard let s = selection, let p = paragraph(containing: s.location) else { return nil }
            return sentences(in: draft, range: p.range).first { NSLocationInRange(s.location, $0) || NSMaxRange($0) == s.location }
        case .greeting:
            guard let first = paragraphs.first,
                  first.text.range(of: #"^(?i)(hi|hello|hey|dear|good (morning|afternoon|evening))\b"#, options: .regularExpression) != nil else { return nil }
            return first.range
        case .signOff:
            guard let i = paragraphs.lastIndex(where: {
                $0.text.range(of: #"^(?i)(best|cheers|thanks|many thanks|thank you|kind regards|regards|all the best|warmly|talk soon|sincerely)\b[^\n]{0,20}$"#,
                              options: .regularExpression) != nil
            }) else { return nil }
            return NSRange(location: paragraphs[i].range.location, length: NSMaxRange(paragraphs.last!.range) - paragraphs[i].range.location)
        }
    }

    /// The draft after a mechanical edit, or nil when the edit doesn't fit the draft.
    public static func apply(_ edit: MechanicalEdit, to draft: String, selection: NSRange?) -> String? {
        let ns = draft as NSString
        let paragraphs = DocumentParagraphs.split(draft)
        func index(_ n: Int) -> Int? {
            let i = n > 0 ? n - 1 : paragraphs.count + n
            return paragraphs.indices.contains(i) ? i : nil
        }
        func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

        switch edit {
        case .move(let p, let to, let after):
            guard let a = index(p), let b = index(to), a != b else { return nil }
            var order = Array(paragraphs.indices).filter { $0 != a }
            guard let at = order.firstIndex(of: b) else { return nil }
            order.insert(a, at: after ? at + 1 : at)
            return DocumentParagraphs.reordered(draft, order: order)
        case .moveToEdge(let p, let top):
            guard let a = index(p) else { return nil }
            var order = Array(paragraphs.indices).filter { $0 != a }
            if top { order.insert(a, at: 0) } else { order.append(a) }
            return DocumentParagraphs.reordered(draft, order: order)
        case .swap(let x, let y):
            guard let a = index(x), let b = index(y), a != b else { return nil }
            var order = Array(paragraphs.indices)
            order.swapAt(a, b)
            return DocumentParagraphs.reordered(draft, order: order)
        case .delete(let place):
            if case .paragraph(let n) = place, let i = index(n) {
                return DocumentParagraphs.replacing(i, with: "", in: draft)
            }
            guard var r = range(of: place, in: draft, selection: selection) else { return nil }
            // Take one neighbouring space with it so no double space is left.
            if NSMaxRange(r) < ns.length, ns.character(at: NSMaxRange(r)) == 32 { r.length += 1 }
            else if r.location > 0, ns.character(at: r.location - 1) == 32 { r.location -= 1; r.length += 1 }
            return ns.replacingCharacters(in: r, with: "")
        case .merge(let x, let y):
            guard let a0 = index(x), let b0 = index(y), a0 != b0 else { return nil }
            let (a, b) = (min(a0, b0), max(a0, b0))
            let merged = paragraphs[a].text.trimmingCharacters(in: .whitespaces) + " " + paragraphs[b].text.trimmingCharacters(in: .whitespaces)
            let withoutB = DocumentParagraphs.replacing(b, with: "", in: draft)
            return DocumentParagraphs.replacing(a, with: merged, in: withoutB)
        case .split(let p, let s):
            guard let i = index(p) else { return nil }
            let sents = sentences(in: draft, range: paragraphs[i].range)
            guard let cut = pick(sents, s), cut != sents.last else { return nil }
            let first = ns.substring(with: NSRange(location: paragraphs[i].range.location, length: NSMaxRange(cut) - paragraphs[i].range.location))
            let rest = ns.substring(with: NSRange(location: NSMaxRange(cut), length: NSMaxRange(paragraphs[i].range) - NSMaxRange(cut)))
            return ns.replacingCharacters(in: paragraphs[i].range,
                                          with: first.trimmingCharacters(in: .whitespaces) + "\n\n" + rest.trimmingCharacters(in: .whitespaces))
        case .replaceExactly(let place, let text):
            guard let r = range(of: place, in: draft, selection: selection) else { return nil }
            let whole: Bool
            switch place {
            case .selection: whole = false
            default: whole = true
            }
            return ns.replacingCharacters(in: r, with: whole ? capitalized(text) : text)
        case .insertExactly(let text, let place, let after):
            guard let place else {
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return capitalized(text) }
                return after ? DocumentParagraphs.appending(capitalized(text), to: draft)
                    : capitalized(text) + "\n\n" + draft.trimmingCharacters(in: .newlines)
            }
            guard let r = range(of: place, in: draft, selection: selection) else { return nil }
            switch place {
            case .paragraph, .currentParagraph, .greeting, .signOff:
                return after ? ns.replacingCharacters(in: NSRange(location: NSMaxRange(r), length: 0), with: "\n\n" + capitalized(text))
                    : ns.replacingCharacters(in: NSRange(location: r.location, length: 0), with: capitalized(text) + "\n\n")
            case .sentence, .currentSentence:
                return after ? ns.replacingCharacters(in: NSRange(location: NSMaxRange(r), length: 0), with: " " + capitalized(text))
                    : ns.replacingCharacters(in: NSRange(location: r.location, length: 0), with: capitalized(text) + " ")
            case .selection:
                return after ? ns.replacingCharacters(in: NSRange(location: NSMaxRange(r), length: 0), with: " " + text)
                    : ns.replacingCharacters(in: NSRange(location: r.location, length: 0), with: text + " ")
            }
        case .bold(let place, let phrase):
            var r: NSRange?
            if let place { r = range(of: place, in: draft, selection: selection) }
            if r == nil, let phrase {
                let found = ns.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive])
                if found.location != NSNotFound { r = found }
                else if let match = TextLocator.find(phrase, in: draft), match.score >= 0.8 { r = NSRange(match.range, in: draft) }
            }
            guard let r, r.length > 0 else { return nil }
            let inner = ns.substring(with: r)
            guard !(inner.hasPrefix("**") && inner.hasSuffix("**")) else { return nil }
            return ns.replacingCharacters(in: r, with: "**" + inner + "**")
        case .list(let p):
            guard let i = index(p) else { return nil }
            let sents = sentences(in: draft, range: paragraphs[i].range).map { ns.substring(with: $0) }
            guard sents.count > 1 else { return nil }
            return ns.replacingCharacters(in: paragraphs[i].range, with: sents.map { "• " + $0 }.joined(separator: "\n"))
        }
    }

    // MARK: For the voice box and the editor

    /// How what was said reads, from the rules alone: the command, what it points at, the exact words.
    /// Empty when the rules find nothing (the local labeler fills in then).
    public static func spans(for utterance: String) -> [SpeechSpan] {
        let ns = utterance as NSString
        func span(_ role: SpanRole, _ r: NSRange) -> SpeechSpan? {
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= ns.length else { return nil }
            return SpeechSpan(role: role, quote: ns.substring(with: r), location: r.location, length: r.length)
        }
        if let parsed = parse(utterance) {
            var result: [SpeechSpan] = []
            if parsed.start > 0, let lead = span(.meta, NSRange(location: 0, length: parsed.start)) { result.append(lead) }
            // Everything that isn't a target or the exact words is the command itself.
            let marked = (parsed.targets + [parsed.exact].compactMap { $0 }).sorted { $0.location < $1.location }
            var cursor = parsed.start
            for r in marked {
                if r.location > cursor, let s = span(.instruction, NSRange(location: cursor, length: r.location - cursor)) { result.append(s) }
                if let s = span(r == parsed.exact ? .payload : .target, r) { result.append(s) }
                cursor = max(cursor, NSMaxRange(r))
            }
            if cursor < ns.length, let s = span(.instruction, NSRange(location: cursor, length: ns.length - cursor)) { result.append(s) }
            return result
        }
        return places(in: utterance).compactMap { span(.target, $0.spoken) }
    }

    /// The rules' spans, with the labeler's filling the gaps between them.
    public static func merged(rules: [SpeechSpan], labels: [SpeechSpan]) -> [SpeechSpan] {
        guard !rules.isEmpty else { return labels }
        let taken = rules.compactMap { s -> NSRange? in
            guard let l = s.location, let n = s.length else { return nil }
            return NSRange(location: l, length: n)
        }
        let extra = labels.filter { s in
            guard let l = s.location, let n = s.length else { return false }
            return !taken.contains { NSIntersectionRange($0, NSRange(location: l, length: n)).length > 0 }
        }
        return (rules + extra).sorted { ($0.location ?? 0) < ($1.location ?? 0) }
    }

    /// The first place named in what's being said, found in the draft: shown while speaking, and told to the editor.
    public static func pointed(in utterance: String, draft: String, selection: NSRange?) -> (place: DraftPlace, range: NSRange)? {
        for (place, _) in places(in: utterance) {
            if let r = range(of: place, in: draft, selection: selection) { return (place, r) }
        }
        return nil
    }

    // MARK: Regex

    /// Capture groups of a case-insensitive match; with `whole`, the pattern must cover the whole string.
    static func groups(_ pattern: String, _ string: String, whole: Bool) -> [String?]? {
        let full = whole ? "^(?:" + pattern + ")$" : pattern
        guard let regex = try? NSRegularExpression(pattern: full, options: [.caseInsensitive]) else { return nil }
        let ns = string as NSString
        guard let m = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}
