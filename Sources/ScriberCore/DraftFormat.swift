import Foundation

/// The little Markdown a draft can hold: "• " bullets, "1. " numbered items, **bold** and *italic*.
/// The text stays plain with the markers in it; the editor draws them as formatting and Done pastes them as HTML.
public enum DraftFormat {
    public enum Inline: Equatable, Sendable { case bold, italic }

    /// A bold or italic run: the whole thing with its markers, and the part that shows.
    public struct Run: Equatable, Sendable {
        public var style: Inline
        public var range: NSRange
        public var content: NSRange

        /// The markers on either side, hidden in the editor.
        public var markers: [NSRange] {
            [NSRange(location: range.location, length: content.location - range.location),
             NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))]
        }
    }

    public static let bullet = "• "

    // MARK: Lists

    /// "• " or "3. " when the line is a list item.
    public static func listPrefix(of line: String) -> String? {
        if line.hasPrefix(bullet) { return bullet }
        guard let match = line.range(of: #"^\d{1,3}\. "#, options: .regularExpression) else { return nil }
        return String(line[match])
    }

    public static func isListItem(_ line: String) -> Bool { listPrefix(of: line) != nil }

    /// What Return starts on the line after `line`: the next bullet or number. Nil when `line` isn't a list item.
    public static func nextPrefix(after line: String) -> String? {
        guard let prefix = listPrefix(of: line) else { return nil }
        if prefix == bullet { return bullet }
        return (Int(prefix.dropLast(2)).map { "\($0 + 1). " }) ?? bullet
    }

    // MARK: From the model

    /// The draft with Markdown the models write turned into the draft's own: "- ", "* " and "+ " items become
    /// "• ", "1) " becomes "1. ", and headings become bold lines. Leading spaces before a list item go (lists are
    /// one level), and so do blank lines inside a list. Applying it twice changes nothing.
    public static func normalized(_ text: String) -> String {
        guard text.contains(where: { "-*+•#).".contains($0) }) else { return text }
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            var line = lines[i]
            if let r = line.range(of: #"^[ \t]*[-*+•][ \t]+(?=\S)"#, options: .regularExpression) {
                line.replaceSubrange(r, with: bullet)
            } else if let r = line.range(of: #"^[ \t]*•(?=\S)"#, options: .regularExpression) {
                line.replaceSubrange(r, with: bullet)
            } else if let r = line.range(of: #"^[ \t]*(\d{1,3})[.)][ \t]+(?=\S)"#, options: .regularExpression) {
                let number = line[r].filter(\.isNumber)
                line.replaceSubrange(r, with: "\(number). ")
            } else if let r = line.range(of: #"^[ \t]*#{1,6}[ \t]+(?=\S)"#, options: .regularExpression) {
                let title = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"^\*\*(.*)\*\*$"#, with: "$1", options: .regularExpression)
                line = "**\(title)**"
            }
            lines[i] = line
        }
        // A list is one block: no blank lines between its items, or between a lead-in ending in ":" and the first.
        var tight: [String] = []
        var i = 0
        while i < lines.count {
            tight.append(lines[i])
            var next = i + 1
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            if next > i + 1, next < lines.count, isListItem(lines[next]),
               isListItem(lines[i]) || lines[i].trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                i = next
                continue
            }
            i += 1
        }
        return tight.joined(separator: "\n")
    }

    // MARK: Inline

    private static let boldPattern = try! NSRegularExpression(pattern: #"\*\*(?=[^\s*])(.+?)(?<=[^\s*])\*\*"#)
    private static let italicPattern = try! NSRegularExpression(pattern: #"(?<![*\w])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![*\w])"#)

    /// Bold and italic runs in `text`, in order. A run never crosses a line; italic inside bold is allowed.
    public static func runs(in text: String) -> [Run] {
        let ns = text as NSString
        var result: [Run] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
            var bold: [Run] = []
            for match in boldPattern.matches(in: text, range: line) {
                bold.append(Run(style: .bold, range: match.range, content: match.range(at: 1)))
            }
            var italic: [Run] = []
            for match in italicPattern.matches(in: text, range: line) {
                // Not a marker of a bold run.
                guard !bold.contains(where: { run in run.markers.contains { NSIntersectionRange($0, match.range).length > 0 } }) else { continue }
                italic.append(Run(style: .italic, range: match.range, content: match.range(at: 1)))
            }
            result += (bold + italic).sorted { $0.range.location < $1.range.location }
        }
        return result
    }

    /// Without bold and italic markers: what plain-text destinations get. Bullets and numbers stay.
    public static func plain(_ text: String) -> String {
        let ns = text as NSString
        let hidden = runs(in: text).flatMap(\.markers).sorted { $0.location > $1.location }
        let out = NSMutableString(string: ns)
        for range in hidden { out.replaceCharacters(in: range, with: "") }
        return out as String
    }

    /// The line as HTML, with bold and italic, after the list prefix is taken off.
    static func inlineHTML(_ line: String) -> String {
        let ns = line as NSString
        let all = runs(in: line)
        var opens: [Int: [String]] = [:]
        var closes: [Int: [String]] = [:]
        var skip = IndexSet()
        for run in all {
            let tag = run.style == .bold ? "strong" : "em"
            opens[run.range.location, default: []].append("<\(tag)>")
            closes[NSMaxRange(run.range), default: []].insert("</\(tag)>", at: 0)
            for marker in run.markers { skip.insert(integersIn: marker.location..<NSMaxRange(marker)) }
        }
        var out = ""
        var plainStart = 0
        func flush(_ end: Int) {
            if end > plainStart { out += ClipboardText.escape(ns.substring(with: NSRange(location: plainStart, length: end - plainStart))) }
        }
        var i = 0
        while i <= ns.length {
            if let tags = closes[i] { flush(i); plainStart = i; out += tags.joined() }
            if let tags = opens[i] { flush(i); plainStart = i; out += tags.joined() }
            if i < ns.length, skip.contains(i) {
                flush(i)
                plainStart = i + 1
            }
            i += 1
        }
        flush(ns.length)
        return out
    }
}
