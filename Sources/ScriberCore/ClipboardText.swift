import Foundation

/// The draft as rich text for pasting. Plain text alone lands as a narrow column in some email editors;
/// simple HTML paragraphs with no fonts or sizes take on the destination's own style instead.
public enum ClipboardText {
    /// One `<div>` per line and `<div><br></div>` for a blank line: the shape web editors produce when you type.
    /// Runs of "• " lines become a `<ul>`, of "1. " lines an `<ol>`; bold and italic become `<strong>` and `<em>`.
    public static func html(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var body = ""
        var openList: String?
        func closeList() {
            if let tag = openList { body += "</\(tag)>" }
            openList = nil
        }
        for line in lines {
            if let prefix = DraftFormat.listPrefix(of: line) {
                let tag = prefix == DraftFormat.bullet ? "ul" : "ol"
                if openList != tag {
                    closeList()
                    let start = Int(prefix.dropLast(2)) ?? 1
                    body += tag == "ol" && start != 1 ? "<ol start=\"\(start)\">" : "<\(tag)>"
                    openList = tag
                }
                body += "<li>\(DraftFormat.inlineHTML(String(line.dropFirst(prefix.count))))</li>"
                continue
            }
            closeList()
            body += line.isEmpty ? "<div><br></div>" : "<div>\(DraftFormat.inlineHTML(line))</div>"
        }
        closeList()
        return "<meta charset=\"utf-8\">" + body
    }

    /// For destinations that only take plain text: no bold or italic markers.
    public static func plain(_ text: String) -> String {
        DraftFormat.plain(text)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// What a context file says, without the guidance comments in its template.
public enum ContextText {
    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
