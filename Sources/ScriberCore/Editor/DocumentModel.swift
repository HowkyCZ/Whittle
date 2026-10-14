import Foundation
import Combine

public enum DocumentOpType: String, Codable, Sendable {
    case append
    case insert
    case replace
    case delete
    case move
    case noDocumentChange = "no_document_change"
}

public struct DocumentOp: Codable, Equatable, Sendable {
    public var op: DocumentOpType
    /// Character offset (UTF-16) — preferred when known.
    public var start: Int?
    public var end: Int?
    public var text: String?
    /// Exact substring to find when moving or anchoring.
    public var anchor: String?
    /// Destination index for move/insert when not using start.
    public var destination: Int?
    /// Structural hints the applier resolves locally.
    public var target: String? // e.g. "first_paragraph", "last_sentence"

    public init(
        op: DocumentOpType,
        start: Int? = nil,
        end: Int? = nil,
        text: String? = nil,
        anchor: String? = nil,
        destination: Int? = nil,
        target: String? = nil
    ) {
        self.op = op
        self.start = start
        self.end = end
        self.text = text
        self.anchor = anchor
        self.destination = destination
        self.target = target
    }
}

public enum ApplyResult: Equatable, Sendable {
    case applied
    case stale
    case failed(String)
}

@MainActor
public final class DocumentModel: ObservableObject {
    @Published public private(set) var text: String = ""
    @Published public private(set) var revision: Int = 0

    private var snapshots: [String] = []
    private var redoStack: [String] = []
    /// When the writer last typed; keystrokes closer together than `typingBurst` are one version.
    private var lastTypedAt: Date?
    public static let typingBurst: TimeInterval = 2

    /// Changes that can still be undone; shown as the version number.
    public var version: Int { snapshots.count }
    public var canUndo: Bool { !snapshots.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init() {}

    /// A change typed by the writer. A burst of typing counts as one version in history.
    public func userEdited(_ newText: String, at date: Date = Date()) {
        guard newText != text else { return }
        if let last = lastTypedAt, date.timeIntervalSince(last) < Self.typingBurst {
            // Same burst: the version before the burst is already saved.
        } else {
            snapshots.append(text)
        }
        lastTypedAt = date
        redoStack.removeAll()
        text = newText
        revision += 1
    }

    @discardableResult
    public func undo() -> Bool {
        guard let previous = snapshots.popLast() else { return false }
        redoStack.append(text)
        text = previous
        revision += 1
        lastTypedAt = nil
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        snapshots.append(text)
        text = next
        revision += 1
        lastTypedAt = nil
        return true
    }

    /// Takes back the change just applied without offering it for redo, e.g. one that broke locked wording.
    @discardableResult
    public func discardLastChange() -> Bool {
        guard let previous = snapshots.popLast() else { return false }
        text = previous
        revision += 1
        lastTypedAt = nil
        return true
    }

    public func apply(ops: [DocumentOp], expectedRevision: Int) -> ApplyResult {
        guard expectedRevision == revision else { return .stale }
        let meaningful = ops.filter { $0.op != .noDocumentChange }
        guard !meaningful.isEmpty else { return .applied }

        snapshots.append(text)
        var working = text

        for op in meaningful {
            do {
                working = try Self.apply(op: op, to: working)
            } catch {
                snapshots.removeLast()
                return .failed(error.localizedDescription)
            }
        }

        // Models write "- " lists and "## " headings; the draft keeps its own "• " and bold.
        text = DraftFormat.normalized(working)
        revision += 1
        redoStack.removeAll()
        lastTypedAt = nil
        return .applied
    }

    public enum ApplierError: LocalizedError {
        case missingText
        case invalidRange
        case anchorNotFound(String)
        case unresolvedTarget(String)

        public var errorDescription: String? {
            switch self {
            case .missingText: return "Op missing text"
            case .invalidRange: return "Invalid range"
            case .anchorNotFound(let a): return "Anchor not found: \(a)"
            case .unresolvedTarget(let t): return "Could not resolve target: \(t)"
            }
        }
    }

    public nonisolated static func apply(op: DocumentOp, to document: String) throws -> String {
        switch op.op {
        case .noDocumentChange:
            return document

        case .append:
            guard let text = op.text else { throw ApplierError.missingText }
            if document.isEmpty { return text }
            let needsBreak = !document.hasSuffix("\n") && !text.hasPrefix("\n")
            return document + (needsBreak ? "\n\n" : "") + text

        case .insert:
            guard let text = op.text else { throw ApplierError.missingText }
            let index = try resolveInsertIndex(op: op, in: document)
            return insert(text, at: index, in: document)

        case .replace:
            guard let text = op.text else { throw ApplierError.missingText }
            let range = try resolveRange(op: op, in: document)
            return replace(range, with: text, in: document)

        case .delete:
            let range = try resolveRange(op: op, in: document)
            return replace(range, with: "", in: document)
                .replacingOccurrences(of: #"[ \t]*\n[ \t]*\n(\s*\n)+"#, with: "\n\n", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]+([.,;:!?])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

        case .move:
            let sourceRange: Range<String.Index>
            if let anchor = op.anchor, let r = document.range(of: anchor) {
                sourceRange = r
            } else if let start = op.start, let end = op.end {
                sourceRange = try utf16Range(start: start, end: end, in: document)
            } else if let target = op.target {
                sourceRange = try resolveStructuralRange(target, in: document)
            } else {
                throw ApplierError.missingText
            }

            let piece = String(document[sourceRange])
            let nsRange = NSRange(sourceRange, in: document)
            let removedStart = nsRange.location
            let removedLen = nsRange.length

            var without = document
            without.replaceSubrange(sourceRange, with: "")

            var dest = op.destination ?? (without as NSString).length
            if dest > removedStart {
                dest -= removedLen
            }
            dest = max(0, min(dest, (without as NSString).length))
            return insert(piece, at: dest, in: without)
        }
    }

    private nonisolated static func resolveInsertIndex(op: DocumentOp, in document: String) throws -> Int {
        if let start = op.start { return start }
        if let destination = op.destination { return destination }
        if let target = op.target {
            let range = try resolveStructuralRange(target, in: document)
            return document.utf16.distance(from: document.utf16.startIndex, to: range.lowerBound)
        }
        return document.utf16.count
    }

    private nonisolated static func resolveRange(op: DocumentOp, in document: String) throws -> Range<String.Index> {
        if let anchor = op.anchor, let r = document.range(of: anchor) {
            return r
        }
        if let start = op.start, let end = op.end {
            return try utf16Range(start: start, end: end, in: document)
        }
        if let target = op.target {
            return try resolveStructuralRange(target, in: document)
        }
        throw ApplierError.invalidRange
    }

    public nonisolated static func resolveStructuralRange(_ target: String, in document: String) throws -> Range<String.Index> {
        let key = target.lowercased().replacingOccurrences(of: " ", with: "_")
        let paragraphs = splitParagraphs(document)

        switch key {
        case "first_paragraph", "paragraph_1", "opening":
            guard let p = paragraphs.first else { throw ApplierError.unresolvedTarget(target) }
            return p.range
        case "last_paragraph":
            guard let p = paragraphs.last else { throw ApplierError.unresolvedTarget(target) }
            return p.range
        case "last_sentence":
            guard let sentence = lastSentenceRange(in: document) else {
                throw ApplierError.unresolvedTarget(target)
            }
            return sentence
        case "whole_document", "document":
            return document.startIndex..<document.endIndex
        default:
            if key.hasPrefix("paragraph_") {
                let n = Int(key.dropFirst("paragraph_".count)) ?? 0
                let idx = n - 1
                guard idx >= 0, idx < paragraphs.count else {
                    throw ApplierError.unresolvedTarget(target)
                }
                return paragraphs[idx].range
            }
            throw ApplierError.unresolvedTarget(target)
        }
    }

    private nonisolated static func splitParagraphs(_ document: String) -> [(range: Range<String.Index>, text: String)] {
        var result: [(Range<String.Index>, String)] = []
        document.enumerateSubstrings(in: document.startIndex..<document.endIndex, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let text = String(document[range]).trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                var end = range.upperBound
                while end > range.lowerBound {
                    let prev = document.index(before: end)
                    if document[prev].isNewline { end = prev } else { break }
                }
                let clean = range.lowerBound..<end
                result.append((clean, String(document[clean])))
            }
        }
        return result
    }

    private nonisolated static func lastSentenceRange(in document: String) -> Range<String.Index>? {
        let separators = CharacterSet(charactersIn: ".!?")
        var last: Range<String.Index>?
        var start = document.startIndex
        for i in document.indices {
            if document[i].unicodeScalars.allSatisfy({ separators.contains($0) }) {
                let end = document.index(after: i)
                let slice = start..<end
                let trimmed = document[slice].trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { last = slice }
                start = end
            }
        }
        if last == nil, !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return document.startIndex..<document.endIndex
        }
        return last
    }

    private nonisolated static func utf16Range(start: Int, end: Int, in document: String) throws -> Range<String.Index> {
        let utf16 = document.utf16
        guard start >= 0, end >= start, end <= utf16.count else { throw ApplierError.invalidRange }
        let lower = utf16.index(utf16.startIndex, offsetBy: start)
        let upper = utf16.index(utf16.startIndex, offsetBy: end)
        guard let s = String.Index(lower, within: document),
              let e = String.Index(upper, within: document) else {
            throw ApplierError.invalidRange
        }
        return s..<e
    }

    private nonisolated static func insert(_ text: String, at utf16Offset: Int, in document: String) -> String {
        let utf16 = document.utf16
        let clamped = max(0, min(utf16Offset, utf16.count))
        let idx16 = utf16.index(utf16.startIndex, offsetBy: clamped)
        let idx = String.Index(idx16, within: document) ?? document.endIndex
        var result = document
        result.insert(contentsOf: text, at: idx)
        return result
    }

    private nonisolated static func replace(_ range: Range<String.Index>, with text: String, in document: String) -> String {
        var result = document
        result.replaceSubrange(range, with: text)
        return result
    }
}
