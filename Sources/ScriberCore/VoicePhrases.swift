import Foundation

/// Push-to-send: speech collects as unsent text until the writer sends it. A few phrases act right away.
public enum VoicePhrases {
    public enum Action: Equatable, Sendable {
        /// Add to the unsent text.
        case append(String)
        /// Add this (possibly nothing) and send everything unsent.
        case send(String)
        /// "Scratch that": drop everything unsent.
        case scratch
        case undo
        case redo
        /// "Stop", "wait": cancel the edit that's being written.
        case cancel
    }

    static let undoPhrases: Set<String> = ["undo", "undo that", "undo it", "undo the last change"]
    static let redoPhrases: Set<String> = ["redo", "redo that", "redo it"]
    static let cancelPhrases: Set<String> = ["stop", "wait", "cancel", "hold on", "stop that"]
    static let scratchPhrases: Set<String> = ["scratch that", "scratch that out", "scratch all that", "scratch it"]

    public static func classify(_ fragment: String) -> Action {
        let text = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = collapse(text)
        if undoPhrases.contains(whole) { return .undo }
        if redoPhrases.contains(whole) { return .redo }
        if cancelPhrases.contains(whole) { return .cancel }
        if scratchPhrases.contains(whole) || scratchPhrases.contains(where: { whole.hasSuffix(" " + $0) }) {
            return .scratch
        }
        if ["send", "send it", "send that", "okay send", "ok send", "okay send it"].contains(whole) {
            return .send("")
        }
        if let range = text.range(of: sendSuffix, options: [.regularExpression, .caseInsensitive]) {
            return .send(String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .append(text)
    }

    /// "…, okay, send." Whisper also hears it as "OK send", "Okay. Send." or "okay, sent".
    static let sendSuffix = #"[\s,;:-]*\b(?:okay|ok|o\.k\.)[\s,.!-]+(?:send|sent)(?:\s+(?:it|that))?[\s.!]*$"#

    static func collapse(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"[\s,.;:!?]+"#, with: " ", options: .regularExpression)
    }

    /// Words the writer asked to keep as spoken: "say exactly …" / "write exactly …".
    public static func exactWording(in speech: String) -> [String] {
        let pattern = #"(?i)\b(?:say|write|put)\s+exactly[:,]?\s*["“]?(.+?)["”]?(?=(?:[,;]\s*(?:and\s+)?(?:then|after|before|and)\b)|[.!?]\s|[.!?]?$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = speech as NSString
        return regex.matches(in: speech, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let words = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
            return words.split(separator: " ").count >= 2 ? words : nil
        }
    }

    /// Speech that asks to keep wording exact.
    public static func asksForExactWording(_ speech: String) -> Bool {
        speech.range(of: #"(?i)\b(?:say|write|put)\s+exactly\b|\bword for word\b"#, options: .regularExpression) != nil
    }
}

/// Spoken approval: "good, the opening works" marks that paragraph as approved.
public enum ApprovalParser {
    /// The parts of the draft the speech approves, in the speaker's words ("the opening").
    public static func references(in speech: String) -> [String] {
        let patterns = [
            #"(?i)\b(the\s+[\p{L}\s'’-]{2,40}?)\s+(?:works|is\s+(?:good|great|perfect|fine|right|spot on)|looks\s+good|reads\s+well|sounds\s+(?:good|great|right))\b"#,
            #"(?i)\b(?:i\s+(?:like|love)|keep)\s+(the\s+[\p{L}\s'’-]{2,40}?)(?=[,.!?]|\s+(?:as it is|as is)|$)"#
        ]
        var found: [String] = []
        let ns = speech as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: speech, range: NSRange(location: 0, length: ns.length)) {
                let reference = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !found.contains(reference) { found.append(reference) }
            }
        }
        return found
    }

    /// Which paragraph (index into `DocumentParagraphs.split`) a reference like "the opening" means.
    public static func paragraph(for reference: String, in document: String) -> Int? {
        let paragraphs = DocumentParagraphs.split(document)
        guard !paragraphs.isEmpty else { return nil }
        // Body paragraphs: not the greeting at the top, not the sign-off and name at the bottom.
        let body = paragraphs.indices.filter { i in
            let text = paragraphs[i].text
            if i == 0, DocumentLint.isGreeting(text) { return false }
            if i >= paragraphs.count - 3, DocumentLint.isSignOff(text) { return false }
            if i == paragraphs.count - 1, i > 0, DocumentLint.isSignOff(paragraphs[i - 1].text) { return false }
            return true
        }
        let key = reference.lowercased()
        if key.range(of: #"\b(opening|intro|introduction|beginning|start|first paragraph|first part)\b"#, options: .regularExpression) != nil {
            return body.first ?? 0
        }
        if key.range(of: #"\b(ending|close|closing|last paragraph|last part|end)\b"#, options: .regularExpression) != nil {
            return body.last ?? paragraphs.count - 1
        }
        if let numbers = CommandParser.paragraphNumbers(reference), let n = numbers.first {
            let index = n == -1 ? paragraphs.count - 1 : n - 1
            return paragraphs.indices.contains(index) ? index : nil
        }
        guard let match = TextLocator.find(reference, in: document) else { return nil }
        let location = NSRange(match.range, in: document).location
        return paragraphs.firstIndex { NSLocationInRange(location, $0.range) || $0.range.location >= location }
    }
}

/// Exact wording the writer locked with "say exactly": shown underlined, never changed by an edit.
public enum LockedWording {
    /// Where each locked phrase sits in the draft (first occurrence).
    public static func ranges(_ locks: [String], in document: String) -> [NSRange] {
        let ns = document as NSString
        return locks.compactMap { lock in
            let range = ns.range(of: lock)
            return range.location == NSNotFound ? nil : range
        }
    }

    /// Locked phrases that were in the draft before a change and are gone after it.
    public static func broken(_ locks: [String], before: String, after: String) -> [String] {
        locks.filter { before.contains($0) && !after.contains($0) }
    }
}

/// "Make this warmer" with text selected: "this" is the selection.
public enum SelectionTarget {
    static let deictic: Set<String> = [
        "this", "that", "it", "these", "those", "this part", "that part", "this bit", "that bit", "this sentence",
        "that sentence", "this line", "the selection", "the selected text", "the selected part", "what i selected",
        "here", "this one", "that one"
    ]

    public static func isDeictic(_ reference: String?) -> Bool {
        guard let reference else { return true }
        return deictic.contains(VoicePhrases.collapse(reference))
    }

    /// Commands whose target is "this"/"that" point at the selection instead.
    public static func apply(_ commands: [SpokenCommand], selection: String) -> [SpokenCommand] {
        commands.map { command in
            switch command {
            case .replace(let target, let with) where isDeictic(target):
                return .replace(target: selection, with: with)
            case .delete(let target) where isDeictic(target):
                return .delete(target: selection)
            case .rewrite(let target, let how) where isDeictic(target):
                return .rewrite(target: selection, how: how)
            case .exact(let text, .after(let anchor)) where isDeictic(anchor):
                return .exact(text: text, position: .after(selection))
            case .exact(let text, .before(let anchor)) where isDeictic(anchor):
                return .exact(text: text, position: .before(selection))
            default:
                return command
            }
        }
    }
}
