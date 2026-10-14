import Foundation

/// Local commands that skip the model. Not a speech classifier —
/// only empty input, undo, and wipe-the-document.
public enum UtterancePolicy {
    public enum Decision: Equatable {
        case ignore(String)
        case clear
        case undo
        case proceed
    }

    public static func decide(_ utterance: String, document: String) -> Decision {
        let t = collapse(utterance)
        if t.isEmpty { return .ignore("empty") }
        if isClearCommand(t) { return .clear }
        if ["undo", "undo that"].contains(t) { return .undo }
        return .proceed
    }

    public static func isClearCommand(_ utterance: String) -> Bool {
        let t = collapse(utterance)
        let patterns = [
            "delete everything", "clear everything", "scratch everything",
            "delete it all", "clear the document", "start over", "wipe it"
        ]
        return patterns.contains { t.contains($0) }
    }

    public static func collapse(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

public enum OpSanitizer {
    public static func isDuplicateAppend(_ text: String, document: String) -> Bool {
        let incoming = normalize(text)
        let existing = normalize(document)
        if incoming.isEmpty { return true }
        if existing.isEmpty { return false }
        if existing.contains(incoming) && incoming.count >= 12 { return true }
        if incoming.contains(existing) && existing.count >= 12 { return true }
        let paras = document
            .components(separatedBy: "\n\n")
            .map { normalize($0) }
            .filter { !$0.isEmpty }
        return paras.contains(incoming)
    }

    private static func normalize(_ s: String) -> String {
        UtterancePolicy.collapse(s)
            .replacingOccurrences(of: #"[\p{P}]"#, with: "", options: .regularExpression)
    }
}
