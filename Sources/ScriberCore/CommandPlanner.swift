import Foundation

/// Resolves an explicit spoken command against the draft. Locating is done here, in code;
/// the model is only asked to write when the command is a rewrite.
public enum CommandPlanner {
    public enum Resolution: Equatable, Sendable {
        case edit(DocumentOp, note: String)
        /// Several ops, each against the result of the previous one.
        case edits([DocumentOp], note: String)
        /// Rewrite `passage` (exact document text at `start`, UTF-16) following `how`.
        case rewrite(passage: String, start: Int, how: String)
        case notFound(String)
    }

    /// `recent` is the text of the paragraphs the last change touched, newest edit first.
    public static func resolve(_ command: SpokenCommand, document: String, recent: [String]) -> Resolution {
        switch command {
        case .replace(let target, let with):
            return replace(target: target, with: with, in: document)
        case .delete(let target):
            return delete(target: target, in: document, recent: recent)
        case .rewrite(let target, let how):
            return rewrite(target: target, how: how, in: document, recent: recent)
        case .exact(let text, let position):
            return insertExact(text, position: position, in: document)
        case .deleteParagraphs(let numbers):
            return deleteParagraphs(numbers, in: document)
        }
    }

    // MARK: - Paragraph numbers

    static func deleteParagraphs(_ numbers: [Int], in document: String) -> Resolution {
        let paragraphs = TextLocator.visibleParagraphs(in: document)
        let indices = numbers.map { $0 == -1 ? paragraphs.count - 1 : $0 - 1 }
        if let missing = indices.first(where: { !paragraphs.indices.contains($0) }) {
            return .notFound("There's no ¶\(missing + 1) — the draft has \(paragraphs.count) — nothing deleted")
        }
        if Set(indices).count == paragraphs.count {
            return .notFound("That would delete the whole draft — say “delete everything” if you mean it")
        }
        // Back to front, so earlier offsets stay valid.
        let ops = Set(indices).sorted(by: >).map { op(.delete, paragraphs[$0], in: document) }
        let labels = Set(indices).sorted().map { "¶\($0 + 1)" }.joined(separator: ", ")
        return .edits(ops, note: "Removed \(labels)")
    }

    // MARK: - Writer appends

    /// The writer often hands back the whole email for an append. Keep only what's new — not the greeting,
    /// sign-off, or sentences the draft already has — and put it above the sign-off.
    /// Nil when nothing in `text` is new.
    public static func mergeAppend(_ text: String, into document: String) -> DocumentOp? {
        guard !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DocumentOp(op: .append, text: text)
        }
        let docLines = Set(TextLocator.visibleParagraphs(in: document).map { DocumentLint.normalize(String(document[$0])) })
        let docText = DocumentLint.normalize(document)
        let draftBlocks = TextLocator.blocks(in: document).map { String(document[$0]) }
        let hasGreeting = draftBlocks.first.map(DocumentLint.isGreeting) ?? false
        let hasClosing = draftBlocks.count > 1 && (draftBlocks.last.map(isClosing) ?? false)

        let kept: [String] = DocumentLint.paragraphs(text).compactMap { block in
            if hasClosing, isClosing(block) { return nil }
            let lines = block.split(separator: "\n").map(String.init).filter { line in
                let n = DocumentLint.normalize(line)
                if n.isEmpty || docLines.contains(n) { return false }
                if n.count > 20, docText.contains(n) { return false }
                if hasGreeting, DocumentLint.isGreeting(line) { return false }
                if hasClosing, DocumentLint.isSignOff(line) { return false }
                return true
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        guard !kept.isEmpty else { return nil }
        let body = kept.joined(separator: "\n\n")
        return insertBeforeSignOff(body, in: document) ?? DocumentOp(op: .append, text: body)
    }

    /// "Best,\nSam", "Thanks!", or a bare name on its own.
    public static func isClosing(_ block: String) -> Bool {
        let t = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if DocumentLint.isSignOff(t) { return true }
        return t.range(of: #"^[A-Z][\p{L}'’-]+(?:\s+[A-Z][\p{L}'’-]+){0,2}$"#, options: .regularExpression) != nil
    }

    // MARK: - Replace

    static func replace(target: String, with raw: String, in document: String) -> Resolution {
        guard let match = TextLocator.find(target, in: document) else {
            return .notFound("Couldn't find “\(target.prefix(60))” in the draft — nothing changed")
        }
        var with = TextLocator.respellNames(raw, using: document)
        let range = absorbRestatedContext(match.range, replacement: with, in: document)
        with = shaped(with, replacing: range, in: document)
        let old = String(document[range])
        return .edit(op(.replace, range, in: document, text: with), note: "Replaced “\(old.prefix(40))” with “\(with.prefix(40))”")
    }

    /// "instead of saying someone from X, say with X" where the draft reads "with someone from X":
    /// the replacement restates "with", so the edited span grows to cover it instead of doubling it.
    static func absorbRestatedContext(_ range: Range<String.Index>, replacement: String, in document: String) -> Range<String.Index> {
        let rep = TextLocator.tokens(replacement).map(\.word)
        let doc = TextLocator.tokens(document)
        guard let firstIndex = doc.firstIndex(where: { $0.range.lowerBound >= range.lowerBound }),
              let lastIndex = doc.lastIndex(where: { $0.range.upperBound <= range.upperBound }) else { return range }
        var lower = range.lowerBound
        var upper = range.upperBound

        for k in stride(from: min(3, rep.count - 1, firstIndex), through: 1, by: -1) {
            let before = doc[(firstIndex - k)..<firstIndex].map(\.word)
            if Array(rep.prefix(k)).elementsEqual(before, by: { TextLocator.similarity($0, $1) > 0 }) {
                lower = doc[firstIndex - k].range.lowerBound
                break
            }
        }
        let available = doc.count - 1 - lastIndex
        for k in stride(from: min(3, rep.count - 1, available), through: 1, by: -1) {
            let after = doc[(lastIndex + 1)...(lastIndex + k)].map(\.word)
            if Array(rep.suffix(k)).elementsEqual(after, by: { TextLocator.similarity($0, $1) > 0 }) {
                upper = doc[lastIndex + k].range.upperBound
                break
            }
        }
        return lower..<upper
    }

    /// Fit spoken words into the sentence they land in: capitalization and end punctuation follow the slot.
    static func shaped(_ text: String, replacing range: Range<String.Index>, in document: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return t }
        let startsSentence = isSentenceStart(range.lowerBound, in: document)
        let isName = TextLocator.names(in: document).contains { t.hasPrefix($0) }
        if startsSentence {
            t = first.uppercased() + t.dropFirst()
        } else if !isName, first.isUppercase, !(t.split(separator: " ").first.map { $0 == "I" || $0.hasPrefix("I'") } ?? false) {
            t = first.lowercased() + t.dropFirst()
        }
        let old = document[range]
        let enders: Set<Character> = [".", "!", "?"]
        if let last = old.last, enders.contains(last) {
            if let tl = t.last, !enders.contains(tl) { t.append(last) }
        } else if let tl = t.last, enders.contains(tl) || tl == "," {
            t.removeLast()
        }
        return t
    }

    static func isSentenceStart(_ index: String.Index, in document: String) -> Bool {
        var i = index
        while i > document.startIndex {
            let prev = document.index(before: i)
            let ch = document[prev]
            if ch == "\n" || ".!?".contains(ch) { return true }
            if !ch.isWhitespace { return false }
            i = prev
        }
        return true
    }

    // MARK: - Delete

    static func delete(target: String?, in document: String, recent: [String]) -> Resolution {
        if target == nil || target?.lowercased() == "it" {
            guard let passage = recent.first, let r = document.range(of: passage) else {
                return .notFound("Not sure what to delete — say which part")
            }
            return .edit(op(.delete, r, in: document), note: "Removed “\(passage.prefix(40))”")
        }
        guard let target, let match = TextLocator.find(target, in: document) else {
            return .notFound("Couldn't find “\(target?.prefix(60) ?? "")” in the draft — nothing deleted")
        }
        var range = match.range
        let sentence = TextLocator.sentenceRange(containing: range, in: document)
        if Double(document[range].count) >= 0.6 * Double(document[sentence].count) { range = sentence }
        if range == document.startIndex..<document.endIndex {
            return .notFound("That would delete the whole draft — say “delete everything” if you mean it")
        }
        return .edit(op(.delete, range, in: document), note: "Removed “\(document[range].prefix(40))”")
    }

    // MARK: - Rewrite

    static func rewrite(target: String?, how: String, in document: String, recent: [String]) -> Resolution {
        let range: Range<String.Index>?
        switch target?.lowercased() {
        case nil:
            range = recent.first.flatMap { document.range(of: $0) } ?? wholeOrNil(document)
        case "it", "everything":
            range = wholeOrNil(document)
        default:
            range = target.flatMap { TextLocator.find($0, in: document)?.range }
        }
        guard let range else {
            return .notFound("Couldn't find “\(target?.prefix(60) ?? "that")” in the draft — nothing changed")
        }
        let start = document.utf16.distance(from: document.utf16.startIndex, to: range.lowerBound)
        return .rewrite(passage: String(document[range]), start: start, how: how)
    }

    static func wholeOrNil(_ document: String) -> Range<String.Index>? {
        document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : document.startIndex..<document.endIndex
    }

    /// The replace op for a finished rewrite, if the passage is still where it was.
    public static func rewriteOp(passage: String, start: Int, text: String, in document: String) -> DocumentOp? {
        let length = (passage as NSString).length
        let ns = document as NSString
        guard start + length <= ns.length, ns.substring(with: NSRange(location: start, length: length)) == passage else { return nil }
        return DocumentOp(op: .replace, start: start, end: start + length, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Exact words

    static func insertExact(_ raw: String, position: SpokenCommand.Position, in document: String) -> Resolution {
        var text = TextLocator.respellNames(raw, using: document).trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first { text = first.uppercased() + text.dropFirst() }
        if let last = text.last, !".!?:".contains(last) { text.append(".") }

        switch position {
        case .end:
            if let op = insertBeforeSignOff(text, in: document) {
                return .edit(op, note: "Added your words above the sign-off")
            }
            return .edit(DocumentOp(op: .append, text: text), note: "Added your words")
        case .after(let anchor), .before(let anchor):
            let isAfter: Bool = { if case .after = position { return true } else { return false } }()
            if let unit = TextLocator.structuralRange(TextLocator.strippedReference(anchor), in: document) {
                let index = isAfter ? unit.upperBound : unit.lowerBound
                let offset = document.utf16.distance(from: document.utf16.startIndex, to: index)
                return .edit(DocumentOp(op: .insert, start: offset, text: isAfter ? "\n\n" + text : text + "\n\n"),
                             note: "Added your words \(isAfter ? "after" : "before") “\(document[unit].prefix(30))”")
            }
            guard let match = TextLocator.find(anchor, in: document) else {
                return .notFound("Couldn't find “\(anchor.prefix(60))” to place it — nothing added")
            }
            let paragraphRange = TextLocator.blocks(in: document).first { $0.contains(match.range.lowerBound) }
            let wholeParagraph = paragraphRange.map { document[$0].count <= document[match.range].count + 2 } ?? false
            let unit = wholeParagraph ? paragraphRange! : TextLocator.sentenceRange(containing: match.range, in: document)
            let index = isAfter ? unit.upperBound : unit.lowerBound
            let offset = document.utf16.distance(from: document.utf16.startIndex, to: index)
            let piece: String
            if wholeParagraph {
                piece = isAfter ? "\n\n" + text : text + "\n\n"
            } else {
                piece = isAfter ? " " + text : text + " "
            }
            return .edit(DocumentOp(op: .insert, start: offset, text: piece),
                         note: "Added your words \(isAfter ? "after" : "before") “\(document[unit].prefix(30))”")
        }
    }

    /// New text belongs above "Best, Sam", not under it.
    public static func insertBeforeSignOff(_ text: String, in document: String) -> DocumentOp? {
        let paragraphs = TextLocator.blocks(in: document)
        guard paragraphs.count >= 2, let last = paragraphs.last, isClosing(String(document[last])) else { return nil }
        let body = DocumentLint.paragraphs(text)
        if body.contains(where: { DocumentLint.isGreeting($0) || DocumentLint.isSignOff($0) }) { return nil }
        let start = document.utf16.distance(from: document.utf16.startIndex, to: last.lowerBound)
        return DocumentOp(op: .insert, start: start, text: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n")
    }

    // MARK: - Helpers

    static func op(_ type: DocumentOpType, _ range: Range<String.Index>, in document: String, text: String? = nil) -> DocumentOp {
        let ns = NSRange(range, in: document)
        return DocumentOp(op: type, start: ns.location, end: ns.location + ns.length, text: text)
    }
}
