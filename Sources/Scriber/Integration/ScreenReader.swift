import AppKit
import ScreenCaptureKit
import Vision
import ScriberCore

/// Reads the text of the window the writer came from, on this Mac: ScreenCaptureKit takes the window's image,
/// Vision reads the text, and only the text is kept. Needs Screen Recording permission.
enum ScreenReader {
    struct Reading: Equatable {
        var app: String
        var title: String
        var text: String
    }

    enum Result: Equatable {
        case read(Reading)
        case failed(String)
        case needsPermission
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards it's a switch in System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// The frontmost window of `pid`, read to text, or why it couldn't be.
    static func readFrontWindow(of pid: pid_t, appName: String) async -> Result {
        guard hasPermission else { return .needsPermission }
        let t0 = Date()
        do {
            // ScreenCaptureKit's own on-screen flag can miss windows; the window server's list decides what's in front.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let order = frontToBackWindowIDs(of: pid)
            let windows = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80
            }
            let onScreen = windows.filter { order[$0.windowID] != nil }
            // The frontmost on-screen window; if the window server lists none (another Space), the app's largest.
            let front = onScreen.min { order[$0.windowID]! < order[$1.windowID]! }
                ?? windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let window = front else {
                TimingLog.write("Screen: no window found for \(appName)")
                return .failed("\(appName) has no window open to read.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            // Twice the window's size, scaled to fit: a window on a 1× display otherwise fills only a corner
            // of the image and its text is too small to read.
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
            config.scalesToFit = true
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let text = try recognize(image)
            TimingLog.write("Screen: read \(text.count) chars from \(appName) “\(window.title ?? "")” in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            guard !text.isEmpty else { return .failed("Nothing readable in \(appName)’s window.") }
            return .read(Reading(app: appName, title: window.title ?? "", text: String(text.prefix(8000))))
        } catch {
            TimingLog.write("Screen: couldn't read \(appName): \(error.localizedDescription)")
            return .failed("Couldn't read \(appName)’s window (\(error.localizedDescription)).")
        }
    }

    private static func frontToBackWindowIDs(of pid: pid_t) -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var order: [CGWindowID: Int] = [:]
        for (index, info) in list.enumerated() where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
            if let id = info[kCGWindowNumber as String] as? CGWindowID { order[id] = index }
        }
        return order
    }

    /// Lines of text in reading order: top to bottom, then left to right.
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = (request.results ?? []).sorted {
            // Vision's origin is bottom-left; same line when the tops are within half a line height.
            abs($0.boundingBox.maxY - $1.boundingBox.maxY) < $0.boundingBox.height / 2
                ? $0.boundingBox.minX < $1.boundingBox.minX
                : $0.boundingBox.maxY > $1.boundingBox.maxY
        }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }
}
