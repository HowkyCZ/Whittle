import AppKit
import Combine
import SwiftUI

struct PreviousAppSnapshot {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String?

    static func capture() -> PreviousAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return PreviousAppSnapshot(
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName
        )
    }

    @discardableResult
    func restore() -> Bool {
        guard let running = NSRunningApplication(processIdentifier: pid) else { return false }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: running)
        }
        return running.activate(options: [.activateAllWindows])
    }
}

@MainActor
final class WritingPanelController {
    private let session: WritingSession
    private var window: NSWindow?
    /// NSWindow holds its delegate weakly.
    private var windowDelegate: PanelWindowDelegate?
    private let hud = DoneHUD()
    private(set) var isVisible = false {
        didSet { if isVisible != oldValue { onVisibilityChange?(isVisible) } }
    }
    var onVisibilityChange: ((Bool) -> Void)?
    private var modeObserver: AnyCancellable?
    /// The width before Review widened the window, to go back to.
    private var narrowWidth: CGFloat = 640

    init(session: WritingSession) {
        self.session = session
        modeObserver = session.$mode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in self?.fit(to: mode) }
    }

    /// Review needs room for the comments: the window widens to 960 and its chrome turns warm grey.
    private func fit(to mode: WritingMode) {
        guard let window else { return }
        let wide: CGFloat = 960
        var frame = window.frame
        if mode == .review {
            if frame.width < wide {
                narrowWidth = frame.width
                frame.size.width = wide
            }
        } else if frame.width >= wide, narrowWidth < wide {
            frame.size.width = narrowWidth
        }
        if let screen = window.screen?.visibleFrame, frame.maxX > screen.maxX {
            frame.origin.x = max(screen.minX, screen.maxX - frame.width)
        }
        window.minSize = NSSize(width: mode == .review ? 900 : 520, height: 600)
        window.backgroundColor = mode == .review ? Theme.nsReviewChrome : Theme.nsBackground
        if frame != window.frame { window.setFrame(frame, display: true, animate: window.isVisible) }
    }

    /// The hotkey: brings the window forward if it's open behind other windows, closes it if it's in front.
    func toggle() {
        if isVisible, NSApp.isActive, window?.isKeyWindow == true {
            // Don't Done on toggle-close; just hide without clipboard
            hide(finish: false)
        } else {
            present()
        }
    }

    /// Opens the panel. `field` is the text field the button was clicked in; `selection` is text selected
    /// anywhere else. With neither (the hotkey), whichever of the two the app in front has.
    func present(field: TextTarget? = nil, selection: SelectedText? = nil) {
        // Already open (maybe behind other windows): bring it forward, aimed at the new field or selection.
        if isVisible, let window {
            if let selection {
                session.setSelection(selection)
            } else if let field {
                let previous = PreviousAppSnapshot.capture()
                session.retarget(field, from: previous)
                readScreen(of: previous)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let previous = PreviousAppSnapshot.capture()
        let target = selection == nil
            ? (field ?? Accessibility.focusedTextTarget().flatMap { $0.pid == previous?.pid ? $0 : nil })
            : nil
        let selected = selection ?? (target == nil ? previous.flatMap { Accessibility.selectedText(frontmost: $0.pid)?.selected } : nil)
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }
        session.open(remembering: previous, target: target)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        isVisible = true
        // A selection is what the writer chose to bring; otherwise the whole window is read.
        if let selected {
            session.setSelection(selected)
        } else {
            readScreen(of: previous)
        }
    }

    /// Reads the window the writer came from, in the background; the banner above the draft shows how it went.
    private func readScreen(of app: PreviousAppSnapshot?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            session.clearSource()
            return
        }
        let name = app.name ?? "App"
        session.beginReadingScreen(app: name)
        guard ScreenReader.hasPermission else {
            if !UserDefaults.standard.bool(forKey: "askedScreenReading") {
                UserDefaults.standard.set(true, forKey: "askedScreenReading")
                ScreenReader.requestPermission()
            }
            session.setScreen(.needsPermission)
            return
        }
        Task { [weak self] in
            let result = await ScreenReader.readFrontWindow(of: app.pid, appName: name)
            guard let self, self.isVisible else { return }
            self.session.setScreen(result)
        }
    }

    func hide(finish: Bool) {
        if finish {
            let frame = window?.frame
            let (previous, target, text) = session.finish()
            window?.orderOut(nil)
            isVisible = false
            hud.show(appName: previous?.name, over: frame)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                let restored = previous?.restore() ?? false
                if let target, restored, await TextInserter.paste(into: target, text: text) {
                    self.hud.inserted()
                } else if !restored, previous != nil {
                    self.hud.restoreFailed()
                }
            }
        } else {
            session.close()
            window?.orderOut(nil)
            isVisible = false
        }
    }

    private func makeWindow() -> NSWindow {
        let root = WritingPanelView(
            session: session,
            onDone: { [weak self] in self?.hide(finish: true) },
            onDiscard: { [weak self] in self?.hide(finish: false) }
        )
        let hosting = NSHostingController(rootView: root)
        let window = WritingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Whittle"
        window.session = session
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // An empty compact toolbar gives the header room and centers the window controls in it.
        window.toolbar = NSToolbar(identifier: "Scriber.panel")
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = Theme.nsBackground
        window.appearance = NSAppearance(named: .aqua)
        window.isMovableByWindowBackground = true
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        // A normal window: it stays put when you switch apps and shows in Mission Control and ⌘Tab.
        // Opened from another Space, it comes to that Space.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 520, height: 600)
        window.setContentSize(NSSize(width: 640, height: 780))
        window.center()
        let delegate = PanelWindowDelegate(onClose: { [weak self] in
            self?.hide(finish: false)
        })
        windowDelegate = delegate
        window.delegate = delegate
        return window
    }
}

private final class PanelWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// ⌘Z with no text field focused still steps back through the draft's history.
final class WritingPanel: NSWindow {
    weak var session: WritingSession?

    private var editingOwnText: Bool {
        guard let textView = firstResponder as? NSTextView else { return false }
        return textView.allowsUndo
    }

    @objc func undo(_ sender: Any?) {
        if editingOwnText { undoManager?.undo() } else { session?.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if editingOwnText { undoManager?.redo() } else { session?.redo() }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return editingOwnText ? (undoManager?.canUndo ?? false) : (session?.canUndo ?? false)
        case #selector(redo(_:)): return editingOwnText ? (undoManager?.canRedo ?? false) : (session?.canRedo ?? false)
        default: return super.validateUserInterfaceItem(item)
        }
    }
}
