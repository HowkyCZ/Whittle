import AppKit
import ScriberCore

@main
enum ScriberMain {
    static func main() {
        // Scriber's models, context files and logs move into Whittle's folder before anything reads them.
        let moved = AppSupport.moveFromPreviousName()
        if !moved.isEmpty { TimingLog.write("Moved from the Scriber folder: \(moved.joined(separator: ", "))") }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // In the Dock and ⌘Tab like any app, unless turned off in the menu bar menu; always in the menu bar.
        let showsInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        app.setActivationPolicy(showsInDock ? .regular : .accessory)
        app.run()
    }
}
