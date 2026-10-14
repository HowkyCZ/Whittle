import Foundation
import ScriberCore

/// The writer's own Markdown files: who they are, how they write, their projects, anything else.
/// They live in one folder; each draft uses the ones the writer picks.
final class ContextStore {
    static let shared = ContextStore()

    /// Used by every new draft when they have something in them.
    static let profileName = "profile.md"
    static let styleName = "writing-style.md"

    var rootURL: URL {
        AppSupport.folder.appendingPathComponent("context", isDirectory: true)
    }

    /// Makes the folder, with blank templates for the two files every draft uses. Never overwrites.
    func ensureSeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for name in [Self.profileName, Self.styleName] {
            let dest = rootURL.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dest.path),
                  let bundled = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "md",
                                                subdirectory: "ContextFiles"),
                  let data = try? Data(contentsOf: bundled) else { continue }
            try? data.write(to: dest)
        }
    }

    func url(_ relative: String) -> URL {
        rootURL.appendingPathComponent(relative)
    }

    /// Every Markdown or text file in the folder and its subfolders, by path.
    func files() -> [URL] {
        let root = rootURL.standardizedFileURL
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { relativeName($0).localizedStandardCompare(relativeName($1)) == .orderedAscending }
    }

    /// "writing-style", "projects/acme": the path inside the folder without the extension.
    func relativeName(_ url: URL) -> String {
        let root = rootURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.deletingPathExtension().path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : url.deletingPathExtension().lastPathComponent
    }

    /// The file's text without template comments; "" when there's nothing else.
    func content(_ url: URL) -> String {
        ContextText.clean((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    func hasContent(_ url: URL) -> Bool { !content(url).isEmpty }
}
