import Foundation

/// Explicit modes the speaker picks by how they start: "replace … with …", "delete …", "make … shorter",
/// "say exactly …". Anything else goes through the labeling pipeline.
public enum SpokenCommand: Equatable, Sendable {
    case replace(target: String, with: String)
    case delete(target: String?)
    case rewrite(target: String?, how: String)
    case exact(text: String, position: Position)
    /// Paragraph numbers as shown in the margin, 1-based; -1 is the last one.
    case deleteParagraphs([Int])

    public enum Position: Equatable, Sendable {
        case end
        case after(String)
        case before(String)
    }

    /// Short name for the mode chip.
    public var mode: String {
        switch self {
        case .replace: return "Replace"
        case .delete, .deleteParagraphs: return "Delete"
        case .rewrite: return "Rewrite"
        case .exact: return "Exact words"
        }
    }

    public var summary: String {
        switch self {
        case .replace(let target, let with):
            return "“\(target.prefix(40))” → “\(with.prefix(40))”"
        case .delete(let target):
            return target.map { "“\($0.prefix(50))”" } ?? "the last change"
        case .deleteParagraphs(let numbers):
            return numbers.map { $0 == -1 ? "last ¶" : "¶\($0)" }.joined(separator: ", ")
        case .rewrite(let target, let how):
            return "\(target.map { "“\($0.prefix(40))”" } ?? "the last change") · \(how.prefix(40))"
        case .exact(let text, let position):
            switch position {
            case .end: return "“\(text.prefix(50))”"
            case .after(let a): return "“\(text.prefix(36))” after “\(a.prefix(24))”"
            case .before(let b): return "“\(text.prefix(36))” before “\(b.prefix(24))”"
            }
        }
    }
}

public enum CommandParser {
    /// Fillers people say before getting to the command.
    static let lead = #"^(?i)(?:(?:okay|ok|so|um+|uh+|and|alright|right|actually|no|nope|wait|hmm+|well|yeah|then|now|please|can you|could you|let's|let us|just)[\s,.!]+)*"#

    /// Every sentence must be a command (or a filler like "No, no."), otherwise this isn't command mode.
    /// A sentence that doesn't parse alone may complete with the next one ("You say X. Just say Y.").
    public static func parseAll(_ utterance: String) -> [SpokenCommand]? {
        let sentences = splitSentences(utterance)
        var commands: [SpokenCommand] = []
        var i = 0
        while i < sentences.count {
            if isFiller(sentences[i]) { i += 1; continue }
            if let command = parse(sentences[i]) {
                if case .delete(let target?) = command, target.lowercased().contains("paragraph"), i + 1 < sentences.count,
                   let joined = parse(sentences[i] + " " + sentences[i + 1]), case .deleteParagraphs = joined {
                    commands.append(joined)
                    i += 2
                    continue
                }
                if case .exact = command, let whole = parse(sentences[i...].joined(separator: " ")) {
                    // Exact words run to the end of what was said.
                    commands.append(whole)
                    break
                }
                commands.append(command)
                i += 1
            } else if i + 1 < sentences.count, let joined = parse(sentences[i] + " " + sentences[i + 1]) {
                commands.append(joined)
                i += 2
            } else {
                return nil
            }
        }
        return commands.isEmpty ? nil : commands
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?".contains(ch) {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out.flatMap(splitConjoined)
    }

    /// "Delete that and also delete the second paragraph" is two commands.
    static func splitConjoined(_ sentence: String) -> [String] {
        let joiner = #"(?i),?\s+and\s+(?:also\s+|then\s+)?(?=(?:delete|remove|replace|change|rewrite|make|add|insert|say exactly)\b)"#
        guard let regex = try? NSRegularExpression(pattern: joiner) else { return [sentence] }
        var parts: [String] = []
        var start = sentence.startIndex
        for m in regex.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) {
            guard let r = Range(m.range, in: sentence) else { continue }
            parts.append(String(sentence[start..<r.lowerBound]))
            start = r.upperBound
        }
        parts.append(String(sentence[start...]))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isFiller(_ sentence: String) -> Bool {
        var t = sentence
        if let r = t.range(of: lead, options: .regularExpression) { t.removeSubrange(r) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    public static func parse(_ utterance: String) -> SpokenCommand? {
        var text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = text.range(of: lead, options: .regularExpression) { text.removeSubrange(r) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let (target, with) = replacement(text) {
            return .replace(target: target, with: with)
        }
        if let exact = exact(text) { return exact }
        if let insert = insert(text) { return insert }
        if let rewrite = rewrite(text) { return rewrite }
        if let delete = delete(text) { return delete }
        return nil
    }

    // MARK: - Patterns

    static func replacement(_ text: String) -> (String, String)? {
        let patterns = [
            #"^(?i)(?:replace|change|swap|switch)\s+(.+?)\s+(?:with|to|into|for)\s+(.+)$"#,
            #"^(?i)instead of(?:\s+saying|\s+writing|\s+having)?\s+(.+?)[,.]?\s+(?:you can\s+)?(?:just\s+)?(?:say|write|use|put|have)\s+(.+)$"#,
            #"^(?i)(?:don'?t|do not|I wouldn'?t)\s+(?:say|write)\s+(.+?)[,.]?\s+(?:you can\s+|but\s+|instead\s+)?(?:just\s+)?(?:say|write)\s+(.+)$"#,
            #"^(?i)where (?:it|you) (?:says?|said|wrote|write)\s+(.+?)[,.]?\s+(?:just\s+)?(?:say|write|put|make it|change it to)\s+(.+)$"#,
            #"^(?i)(?:in the email[,.]?\s+)?(?:you say|you wrote|it says)\s+(.+?)[,.]\s+(?:just\s+)?(?:say|write|make it)\s+(.+)$"#
        ]
        for pattern in patterns {
            if let groups = match(pattern, text), groups.count == 2 {
                let target = trimQuote(groups[0])
                let with = trimQuote(groups[1])
                if !target.isEmpty, !with.isEmpty { return (target, with) }
            }
        }
        return nil
    }

    static func exact(_ text: String) -> SpokenCommand? {
        let pattern = #"^(?i)(?:say exactly|write exactly|type exactly|literally write|add exactly|add the words?|add the line|add the sentence)[:,]?\s+(.+)$"#
        guard let groups = match(pattern, text), let body = groups.first else { return nil }
        var words = trimQuote(body)
        var position: SpokenCommand.Position = .end
        let placement = #"(?i)[,.]?\s+(after|before|below|above|under|at the end of|at the start of)\s+(?:the\s+)?(?:part\s+(?:about|where|that says)\s+|sentence\s+(?:about|where)\s+|line\s+)?(.+)$"#
        if let groups = match(placement, words), groups.count == 2,
           let r = words.range(of: placement, options: .regularExpression) {
            let anchor = trimQuote(groups[1])
            switch groups[0].lowercased() {
            case "after", "below", "under", "at the end of": position = .after(anchor)
            default: position = .before(anchor)
            }
            words = trimQuote(String(words[..<r.lowerBound]))
        }
        guard !words.isEmpty else { return nil }
        return .exact(text: words, position: position)
    }

    static func rewrite(_ text: String) -> SpokenCommand? {
        if let groups = match(#"^(?i)(?:rewrite|rephrase|reword|redo)\s+(.+?)(?:[,.]?\s+(?:to be|so (?:that )?it(?:'s| is)?|as|to sound|and make it|make it)\s+(.+))?$"#, text) {
            let target = targetOrNil(groups[0])
            let how = groups.count > 1 && !groups[1].isEmpty ? trimQuote(groups[1]) : "clearer"
            return .rewrite(target: target, how: how)
        }
        let adjective = #"(?:[a-z]+er|(?:more|less)\s+[a-z]+|casual|formal|concise|polite|direct|friendly|professional|personal|warm|short|brief|simple|clear|human|natural|fluent|crisp)"#
        let quality = #"(?:(?:a (?:bit|little|lot)|much|way|slightly|even|super)\s+)*"# + adjective + #"(?:\s+and\s+"# + adjective + #")?"#
        let target = #"(it|this|that|everything|(?:the|this|that|my|our)\s+.+?)"#
        if let groups = match(#"^(?i)make\s+"# + target + #"\s+("# + quality + #")[.!]?$"#, text), groups.count == 2 {
            return .rewrite(target: targetOrNil(groups[0]), how: groups[1])
        }
        if let groups = match(#"^(?i)(shorten|tighten|soften|expand|simplify|clean up|polish)\s+(.+?)[.!]?$"#, text), groups.count == 2 {
            return .rewrite(target: targetOrNil(groups[1]), how: groups[0].lowercased())
        }
        return nil
    }

    static func delete(_ text: String) -> SpokenCommand? {
        guard let groups = match(#"^(?i)(?:delete|remove|cut|drop|get rid of|take out|scrap)\s+(.+?)[.!]?$"#, text),
              let target = groups.first else { return nil }
        let lowered = target.lowercased()
        if ["everything", "all of it", "it all", "the whole thing"].contains(lowered) { return nil }
        if let numbers = paragraphNumbers(target) { return .deleteParagraphs(numbers) }
        return .delete(target: targetOrNil(target))
    }

    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "last": -1, "final": -1,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10
    ]

    /// "the second, third and seventh paragraph", "paragraphs 2, 3 and 7" → [2, 3, 7].
    /// Nil if the phrase says anything besides paragraph numbers ("the paragraph about pricing").
    public static func paragraphNumbers(_ phrase: String) -> [Int]? {
        let lowered = phrase.lowercased()
        guard lowered.range(of: #"paragraph|\bpara\b|¶"#, options: .regularExpression) != nil else { return nil }
        let filler: Set<String> = ["the", "and", "also", "these", "those", "paragraph", "paragraphs", "para", "number",
                                   "numbers", "¶", "then", "both", "or"]
        var numbers: [Int] = []
        for word in lowered.split(whereSeparator: { $0.isWhitespace || ",.;&".contains($0) }).map(String.init) {
            let w = word.replacingOccurrences(of: "¶", with: "")
            if filler.contains(word) || w.isEmpty { continue }
            if let n = Int(w) ?? Int(w.replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression)) ?? ordinals[w] {
                if !numbers.contains(n) { numbers.append(n) }
            } else {
                return nil
            }
        }
        return numbers.isEmpty ? nil : numbers
    }

    /// "Add a paragraph after the greeting saying X", "add a sentence saying X before the sign-off",
    /// "after the second paragraph, add X". The words after "saying" go in as said.
    static func insert(_ text: String) -> SpokenCommand? {
        let verb = #"(?:add|insert|put|write|include)"#
        let unit = #"(?:(?:a|an|another|a new|one more)\s+)?(?:short\s+)?(?:paragraph|sentence|line|bit|part|note|p\.?s\.?)"#
        let say = #"(?:saying|that says|which says|that reads|with the words|reading)"#
        let place = #"((?:right\s+)?(?:between|after|before|below|above|under|at the (?:end|start|beginning|top|bottom))\b.*?)"#

        if let g = match(#"^(?i)"# + verb + #"\s+(?:"# + unit + #"\s+)?"# + place + #"[,:]?\s+"# + say + #"[,:]?\s+(.+)$"#, text),
           g.count == 2, let position = position(g[0]) {
            return literal(g[1], position)
        }
        if let g = match(#"^(?i)"# + verb + #"\s+"# + unit + #"\s+"# + say + #"[,:]?\s+(.+?)(?:[,.]?\s+"# + place + #")?[.!]?$"#, text) {
            let body = g[0]
            if g.count > 1, !g[1].isEmpty, isStructuralPlace(g[1]), let position = position(g[1]) {
                return literal(body, position)
            }
            let whole = g.count > 1 && !g[1].isEmpty ? body + " " + g[1] : body
            return literal(whole, .end)
        }
        if let g = match(#"^(?i)"# + place + #",\s+"# + verb + #"(?:\s+"# + unit + #")?(?:\s+"# + say + #")?[,:]?\s+(.+)$"#, text),
           g.count == 2, let position = position(g[0]) {
            return literal(g[1], position)
        }
        return nil
    }

    private static func literal(_ raw: String, _ position: SpokenCommand.Position) -> SpokenCommand? {
        let words = trimQuote(raw)
        return words.isEmpty ? nil : .exact(text: words, position: position)
    }

    static func isStructuralPlace(_ place: String) -> Bool {
        place.range(of: #"(?i)paragraph|sign.?off|greeting|signature|sentence|\bend\b|\bstart\b|beginning|top|bottom"#, options: .regularExpression) != nil
    }

    /// "between the second and the third paragraph" → after the second paragraph.
    static func position(_ place: String) -> SpokenCommand.Position? {
        let p = trimQuote(place).replacingOccurrences(of: #"(?i)^right\s+"#, with: "", options: .regularExpression)
        if let g = match(#"^(?i)between\s+(?:the\s+)?(\S+)(?:\s+paragraph)?\s+and\s+(?:the\s+)?\S+(?:\s+paragraphs?)?$"#, p), let first = g.first {
            return .after("\(first) paragraph")
        }
        if p.range(of: #"(?i)^at the (?:end|bottom)$"#, options: .regularExpression) != nil { return .end }
        if p.range(of: #"(?i)^at the (?:start|beginning|top)$"#, options: .regularExpression) != nil { return .before("first paragraph") }
        guard let g = match(#"^(?i)(after|before|below|above|under|at the end of|at the (?:start|beginning|top) of)\s+(.+)$"#, p), g.count == 2 else { return nil }
        let anchor = trimQuote(g[1])
        guard !anchor.isEmpty else { return nil }
        switch g[0].lowercased() {
        case "after", "below", "under", "at the end of": return .after(anchor)
        default: return .before(anchor)
        }
    }

    /// "that", "the last part you said" mean the most recent change (nil). "it" stays: the planner decides
    /// whether it means the draft ("make it warmer") or the last change ("delete it").
    static func targetOrNil(_ raw: String) -> String? {
        let t = trimQuote(raw)
        let lowered = t.lowercased()
        let recent = #"^(?:that|this|that part|this part|that bit|the last (?:part|bit|thing|sentence|paragraph|line)(?: (?:you|I) (?:said|wrote|added))?|what you (?:just )?(?:said|wrote|added)|the last thing|the thing you (?:just )?(?:said|wrote|added))$"#
        if lowered.range(of: recent, options: .regularExpression) != nil { return nil }
        return t.isEmpty ? nil : t
    }

    static func trimQuote(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’,:;."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
