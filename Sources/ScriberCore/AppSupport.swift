import Foundation

/// Where Whittle keeps its files: ~/Library/Application Support/Whittle. It used to be called Scriber.
public enum AppSupport {
    public static let name = "Whittle"
    static let previousName = "Scriber"

    public static var folder: URL {
        base.appendingPathComponent(name, isDirectory: true)
    }

    public static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    /// Moves what Scriber kept (Whisper models, context files, logs) into Whittle's folder, so nothing is downloaded
    /// again. A folder both have is merged one level down; a file both have keeps the old one as "name (Scriber)".
    /// The old folder goes once it's empty. Returns what moved.
    @discardableResult
    public static func moveFromPreviousName(base: URL = AppSupport.base) -> [String] {
        let fm = FileManager.default
        let old = base.appendingPathComponent(previousName, isDirectory: true)
        let new = base.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return [] }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        var moved: [String] = []

        func move(_ from: URL, into folder: URL, label: String, depth: Int) {
            let item = from.lastPathComponent
            guard item != ".DS_Store" else { return }
            var destination = folder.appendingPathComponent(item)
            var isFolder: ObjCBool = false
            if fm.fileExists(atPath: destination.path, isDirectory: &isFolder) {
                var sourceIsFolder: ObjCBool = false
                fm.fileExists(atPath: from.path, isDirectory: &sourceIsFolder)
                if isFolder.boolValue, sourceIsFolder.boolValue, depth == 0 {
                    for child in (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? [] {
                        move(child, into: destination, label: label + "/" + child.lastPathComponent, depth: depth + 1)
                    }
                    removeIfEmpty(from)
                    return
                }
                let ext = (item as NSString).pathExtension
                let stem = (item as NSString).deletingPathExtension
                destination = folder.appendingPathComponent(stem + " (\(previousName))" + (ext.isEmpty ? "" : "." + ext))
                guard !fm.fileExists(atPath: destination.path) else { return }
            }
            if (try? fm.moveItem(at: from, to: destination)) != nil { moved.append(label) }
        }

        func removeIfEmpty(_ folder: URL) {
            let left = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != ".DS_Store" }
            if left.isEmpty { try? fm.removeItem(at: folder) }
        }

        for item in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
            move(item, into: new, label: item.lastPathComponent, depth: 0)
        }
        removeIfEmpty(old)
        return moved.sorted()
    }
}
