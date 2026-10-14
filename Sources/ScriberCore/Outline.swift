import Foundation

/// A point a section has to make, ticked by the model when the section's paragraphs make it.
public struct OutlinePoint: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var covered: Bool

    public init(id: String, text: String, covered: Bool = false) {
        self.id = id
        self.text = text
        self.covered = covered
    }
}

/// One part of the plan: a group of the draft's paragraphs, or a place where they will go.
public struct OutlineSection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Why the section is there, when the writer explained it at length.
    public var why: String
    public var points: [OutlinePoint]
    /// The draft's paragraphs (0-based, as numbered in the margin) written for this section.
    public var paragraphs: [Int]

    public init(id: String, title: String, why: String = "", points: [OutlinePoint] = [], paragraphs: [Int] = []) {
        self.id = id
        self.title = title
        self.why = why
        self.points = points
        self.paragraphs = paragraphs
    }

    public var isWritten: Bool { !paragraphs.isEmpty }
}

/// How a point shows: a green check, an empty box, or orange when its section is written without it.
public enum PointStatus: Equatable, Sendable {
    case covered, notWritten, missing
}

/// Structure mode's plan for the draft. It's a second view of the same document, not a copy: sections point
/// at paragraphs, and the text stays in the draft.
public struct Outline: Equatable, Sendable {
    public var sections: [OutlineSection]
    /// The draft the paragraph numbers were read from. They're only trusted while the draft is unchanged.
    public var checkedDraft: String?

    public init(sections: [OutlineSection] = [], checkedDraft: String? = nil) {
        self.sections = sections
        self.checkedDraft = checkedDraft
    }

    public var isEmpty: Bool { sections.isEmpty }
    public var writtenCount: Int { sections.filter(\.isWritten).count }
    public var unwritten: [OutlineSection] { sections.filter { !$0.isWritten } }

    public func isCurrent(for draft: String) -> Bool { checkedDraft == draft }

    public func status(of point: OutlinePoint, in section: OutlineSection) -> PointStatus {
        if point.covered { return .covered }
        return section.isWritten ? .missing : .notWritten
    }

    // MARK: For the model

    /// The outline as the model reads it, with the ids it has to keep.
    public func described() -> String {
        guard !sections.isEmpty else { return "(no sections yet)" }
        return sections.map { section in
            var lines = ["[\(section.id)] \(section.title) — "
                + (section.isWritten ? "written as " + section.paragraphs.map { "p\($0 + 1)" }.joined(separator: ", ") : "not written yet")]
            if !section.why.isEmpty { lines.append("  why: \(section.why)") }
            for point in section.points {
                lines.append("  - [\(point.id)] \(point.text)\(point.covered ? " (covered)" : "")")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// The model's reply: the whole outline after the change. Keeps known ids, numbers new sections and points,
    /// and gives each paragraph to one section at most. Returns the ids of new sections too.
    public func merging(_ reply: OutlineReply, draft: String) -> (outline: Outline, added: [String], write: [String]) {
        let count = DocumentParagraphs.split(draft).count
        var known = Set(sections.map(\.id))
        var knownPoints = Set(sections.flatMap { $0.points.map(\.id) })
        var next = (sections.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        var taken = Set<Int>()
        var added: [String] = []
        var newIDs: [String] = []

        var result: [OutlineSection] = []
        for item in reply.sections {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            var id = item.id.trimmingCharacters(in: .whitespaces)
            if !known.contains(id) || result.contains(where: { $0.id == id }) {
                id = "s\(next)"
                next += 1
                added.append(id)
                newIDs.append(id)
                known.insert(id)
            }
            var points: [OutlinePoint] = []
            var pointNumber = 1
            for point in item.points {
                let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var pid = point.id.trimmingCharacters(in: .whitespaces)
                if !knownPoints.contains(pid) || points.contains(where: { $0.id == pid }) {
                    repeat {
                        pid = "\(id).\(pointNumber)"
                        pointNumber += 1
                    } while knownPoints.contains(pid)
                    knownPoints.insert(pid)
                }
                points.append(OutlinePoint(id: pid, text: text, covered: point.covered))
            }
            var paragraphs: [Int] = []
            for ref in item.paragraphs {
                guard let n = Int(ref.trimmingCharacters(in: .whitespaces).dropFirst()), n >= 1, n <= count,
                      !taken.contains(n - 1) else { continue }
                taken.insert(n - 1)
                paragraphs.append(n - 1)
            }
            // A section with no text can't have covered anything.
            if paragraphs.isEmpty { for i in points.indices { points[i].covered = false } }
            result.append(OutlineSection(id: id, title: title, why: item.why.trimmingCharacters(in: .whitespacesAndNewlines),
                                         points: points, paragraphs: paragraphs.sorted()))
        }

        // "new" in write means the sections that were just added, in order.
        var write: [String] = []
        var newQueue = newIDs[...]
        for ref in reply.write {
            let ref = ref.trimmingCharacters(in: .whitespaces)
            if result.contains(where: { $0.id == ref }) {
                if !write.contains(ref) { write.append(ref) }
            } else if let id = newQueue.popFirst(), !write.contains(id) {
                write.append(id)
            }
        }
        return (Outline(sections: result, checkedDraft: draft), added, write)
    }

    // MARK: Moving written text

    /// The draft with its paragraphs in the outline's order, when sections were moved. Paragraphs before the
    /// first section's text (a greeting) and after the last (a sign-off) stay where they are; any other paragraph
    /// travels with the section before it. Nil when the order already matches.
    public static func regroup(_ draft: String, sections: [OutlineSection]) -> (draft: String, sections: [OutlineSection])? {
        let paragraphs = DocumentParagraphs.split(draft)
        guard !paragraphs.isEmpty else { return nil }
        var group = [Int?](repeating: nil, count: paragraphs.count)
        for (index, section) in sections.enumerated() {
            for p in section.paragraphs where group.indices.contains(p) && group[p] == nil { group[p] = index }
        }
        guard let first = group.firstIndex(where: { $0 != nil }), let last = group.lastIndex(where: { $0 != nil }) else { return nil }
        for i in first...last where group[i] == nil { group[i] = group[i - 1] }

        var order = Array(0..<first)
        for index in sections.indices { order += (first...last).filter { group[$0] == index } }
        order += Array((last + 1)..<paragraphs.count)
        guard order != Array(paragraphs.indices) else { return nil }

        let text = DocumentParagraphs.reordered(draft, order: order)

        var newIndex = [Int](repeating: 0, count: paragraphs.count)
        for (position, old) in order.enumerated() { newIndex[old] = position }
        let moved = sections.map { section -> OutlineSection in
            var section = section
            section.paragraphs = section.paragraphs.filter { newIndex.indices.contains($0) }.map { newIndex[$0] }.sorted()
            return section
        }
        return (text, moved)
    }

    // MARK: Writing

    /// What the editor is asked when sections are written: each section with its points and where it goes.
    public func writeRequest(for ids: [String], draft: String) -> String? {
        let wanted = sections.filter { ids.contains($0.id) }
        guard !wanted.isEmpty else { return nil }
        let count = DocumentParagraphs.split(draft).count
        var lines = ["Write these sections of my outline as new paragraphs, in my voice. Cover every point listed and add nothing else. Put each where it belongs in the outline's order. Don't change the other paragraphs."]
        for section in wanted {
            guard let index = sections.firstIndex(where: { $0.id == section.id }) else { continue }
            let before = sections[..<index].last(where: \.isWritten)
            let after = sections[(index + 1)...].first(where: \.isWritten)
            var place: String
            if let before, let p = before.paragraphs.max() {
                place = "after p\(p + 1) (the end of “\(before.title)”)"
            } else if let after, let p = after.paragraphs.min() {
                place = "before p\(p + 1) (the start of “\(after.title)”)"
            } else {
                place = count == 0 ? "as the start of the draft" : "in the body, above any sign-off"
            }
            if let previous = sections[..<index].last, wanted.contains(where: { $0.id == previous.id }), !previous.isWritten {
                place = "right after “\(previous.title)”"
            }
            var line = "- Section “\(section.title)”, \(place)."
            if !section.why.isEmpty { line += " Why it's there: \(section.why)." }
            let points = section.points.map(\.text)
            line += points.isEmpty ? " Say what the title says, briefly." : " Must say: " + points.joined(separator: "; ") + "."
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// What the model sends back in Structure mode: the whole outline, sections to write now, and a reply.
public struct OutlineReply: Codable, Equatable, Sendable {
    public struct Section: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var why: String
        public var points: [Point]
        public var paragraphs: [String]

        public init(id: String, title: String, why: String = "", points: [Point] = [], paragraphs: [String] = []) {
            self.id = id
            self.title = title
            self.why = why
            self.points = points
            self.paragraphs = paragraphs
        }
    }

    public struct Point: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var covered: Bool

        public init(id: String, text: String, covered: Bool = false) {
            self.id = id
            self.text = text
            self.covered = covered
        }
    }

    public var sections: [Section]
    public var write: [String]
    public var reply: String

    public init(sections: [Section], write: [String] = [], reply: String = "") {
        self.sections = sections
        self.write = write
        self.reply = reply
    }

    public static func parse(_ raw: String) -> OutlineReply? {
        guard let json = InterpreterJSON.extractJSONObject(raw), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OutlineReply.self, from: data)
    }

    public static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["sections", "write", "reply"],
        "properties": [
            "sections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "title", "why", "points", "paragraphs"],
                    "properties": [
                        "id": ["type": "string"],
                        "title": ["type": "string"],
                        "why": ["type": "string"],
                        "points": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "required": ["id", "text", "covered"],
                                "properties": [
                                    "id": ["type": "string"],
                                    "text": ["type": "string"],
                                    "covered": ["type": "boolean"]
                                ]
                            ]
                        ],
                        "paragraphs": ["type": "array", "items": ["type": "string"]]
                    ]
                ]
            ],
            "write": ["type": "array", "items": ["type": "string"]],
            "reply": ["type": "string"]
        ]
    ]
}
