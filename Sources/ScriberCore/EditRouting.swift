import Foundation

/// Which ChatGPT model an edit goes to. Everyday changes go to the fast model (about 4–5 s); reworking the whole
/// draft, condensing or restructuring, and long spoken briefs go to the thorough one (about 9–14 s), which handled
/// those better when real requests were replayed through both.
public enum EditRouting {
    static let wholeDraftCues = [
        "bullet", "summar", "condense", "restructure", "reorganis", "reorganiz", "rewrite the whole", "rewrite everything",
        "rewrite it all", "whole draft", "whole thing", "whole email", "whole note", "entire", "all of it", "turn it into",
        "turn this into", "make it into", "as a list", "into a list", "outline", "shorten everything", "tighten everything",
    ]

    /// More than this many words of speech is a brief worth the thorough model.
    public static let longBriefWords = 70

    public static func needsThorough(_ speech: String) -> Bool {
        let t = speech.lowercased()
        if wholeDraftCues.contains(where: { t.contains($0) }) { return true }
        return speech.split(whereSeparator: \.isWhitespace).count > longBriefWords
    }
}
