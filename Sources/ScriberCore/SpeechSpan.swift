import Foundation

public enum SpanRole: String, Codable, Sendable, CaseIterable {
    case meta
    case target
    case instruction
    case payload
    case brief
    case constraint

    /// The name used in prompts and on screen.
    public var promptName: String {
        switch self {
        case .meta: return "aside"
        case .target: return "where"
        case .instruction: return "ask"
        case .payload: return "words"
        case .brief: return "gist"
        case .constraint: return "tone"
        }
    }

    /// Accepts both internal names and the friendlier labels the model is prompted with.
    public static func parse(_ raw: String) -> SpanRole? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "meta", "aside": return .meta
        case "target", "where": return .target
        case "instruction", "ask": return .instruction
        case "payload", "words": return .payload
        case "brief", "gist": return .brief
        case "constraint", "tone": return .constraint
        default: return nil
        }
    }
}

public struct SpeechSpan: Equatable, Sendable, Codable {
    public var role: SpanRole
    public var quote: String
    /// UTF-16 range in the utterance the span was labeled from.
    public var location: Int?
    public var length: Int?

    public init(role: SpanRole, quote: String, location: Int? = nil, length: Int? = nil) {
        self.role = role
        self.quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        self.location = location
        self.length = length
    }
}

public struct LabeledRun: Equatable, Sendable {
    public var text: String
    public var role: SpanRole?

    public init(text: String, role: SpanRole? = nil) {
        self.text = text
        self.role = role
    }
}

public enum SpanAligner {
    public static func runs(utterance: String, spans: [SpeechSpan]) -> [LabeledRun] {
        guard !utterance.isEmpty else { return [] }
        let ns = utterance as NSString

        var hits: [(start: Int, end: Int, role: SpanRole)] = []
        for span in spans {
            if let loc = span.location, let len = span.length, loc >= 0, loc + len <= ns.length, len > 0 {
                hits.append((loc, loc + len, span.role))
                continue
            }
            guard span.quote.count >= 2 else { continue }
            let range = ns.range(of: span.quote, options: [.caseInsensitive])
            guard range.location != NSNotFound else { continue }
            hits.append((range.location, range.location + range.length, span.role))
        }
        hits.sort { $0.start < $1.start }

        var runs: [LabeledRun] = []
        var cursor = 0
        for hit in hits where hit.start >= cursor {
            if hit.start > cursor {
                runs.append(LabeledRun(text: ns.substring(with: NSRange(location: cursor, length: hit.start - cursor))))
            }
            runs.append(LabeledRun(
                text: ns.substring(with: NSRange(location: hit.start, length: hit.end - hit.start)),
                role: hit.role
            ))
            cursor = hit.end
        }
        if cursor < ns.length {
            runs.append(LabeledRun(text: ns.substring(from: cursor)))
        }
        return runs
    }
}
