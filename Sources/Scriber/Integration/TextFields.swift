import AppKit
import ApplicationServices
import SwiftUI
import ScriberCore

/// A text field in another app that Scriber can write into.
struct TextTarget {
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    /// Screen frame in AppKit coordinates (origin bottom-left).
    let frame: CGRect
    /// What was selected in the field when Scriber was opened; Done replaces it.
    let selectedText: String
    var bundleID: String?
    /// The field's window, in AppKit screen coordinates.
    var window: CGRect?
    /// Where the caret is, in AppKit screen coordinates, when the app says.
    var caret: CGRect?
    /// The caret moved since the last look: the writer is typing or clicking around.
    var caretMoving = false

    func isSameField(as other: TextTarget?) -> Bool {
        guard let other else { return false }
        return pid == other.pid && CFEqual(element, other.element)
    }
}

/// Text the writer selected in another app and opened Scriber from.
struct SelectedText: Equatable {
    var app: String
    var window: String
    var text: String
}

/// The Accessibility API, which lets Scriber see the focused text field in any app and paste into it.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The system prompt that leads to Privacy & Security → Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Chrome and Electron apps only expose their text fields once asked to.
    private static var webAccessibilityEnabled: Set<pid_t> = []
    private static let lock = NSLock()

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        // Accessibility measures from the top-left of the main screen; AppKit from the bottom-left.
        // (CoreGraphics, not NSScreen: this runs off the main thread.)
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: origin.x, y: mainHeight - origin.y - extent.height, width: extent.width, height: extent.height)
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    /// Text fields, text areas and editable web content; never password fields.
    static func isEditableText(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        if string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return false }
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) {
            return isSettable(element, kAXValueAttribute) || isSettable(element, kAXSelectedTextAttribute)
        }
        // contenteditable in browsers: an editable element that has a caret.
        return isSettable(element, kAXValueAttribute) && string(element, kAXSelectedTextAttribute) != nil
    }

    /// The text field that has focus right now in the frontmost app (never Scriber).
    /// The app comes from NSWorkspace: the system-wide "focused application" query fails on some Macs.
    static func focusedTextTarget(frontmost pid: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier) -> TextTarget? {
        guard isTrusted, let pid, pid != getpid(), pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return textTarget(in: app, pid: pid)
    }

    /// The focused text field of one app.
    static func textTarget(in app: AXUIElement, pid: pid_t) -> TextTarget? {
        enableWebAccessibility(app, pid: pid)
        guard let field = element(app, kAXFocusedUIElementAttribute), isEditableText(field),
              var fieldFrame = frame(of: field), fieldFrame.width > 30, fieldFrame.height > 12 else { return nil }
        // Web text areas can report the whole page; keep the button on the visible window.
        let windowFrame = element(field, kAXWindowAttribute).flatMap { frame(of: $0) }
        if let windowFrame {
            fieldFrame = fieldFrame.intersection(windowFrame)
            if fieldFrame.isNull || fieldFrame.isEmpty { return nil }
        }
        let running = NSRunningApplication(processIdentifier: pid)
        // A caret outside the field, or as tall as several lines (Chromium answers with the whole field), is a wrong
        // answer, not a place.
        let caret = caretBounds(of: field).flatMap {
            fieldFrame.insetBy(dx: -8, dy: -8).contains(CGPoint(x: $0.midX, y: $0.midY)) && $0.height <= 48 ? $0 : nil
        }
        return TextTarget(element: field, pid: pid, appName: running?.localizedName ?? "the app", frame: fieldFrame,
                          selectedText: string(field, kAXSelectedTextAttribute) ?? "", bundleID: running?.bundleIdentifier,
                          window: windowFrame, caret: caret)
    }

    /// The caret (or the end of the selection) in a text field, in AppKit screen coordinates. Native fields say
    /// it through the selected range, web views through text markers. Nil when the app doesn't say.
    static func caretBounds(of field: AXUIElement) -> CGRect? {
        if let rangeValue = value(field, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                // An empty range often has no bounds: measure the letter before the caret and take its right edge,
                // unless it's a line break (then the caret starts the next line: the letter after, left edge).
                let end = range.location + range.length
                func bounds(_ location: Int) -> CGRect? {
                    var one = CFRange(location: location, length: 1)
                    guard location >= 0, let parameter = AXValueCreate(.cfRange, &one) else { return nil }
                    return rect(parameterized(field, kAXBoundsForRangeParameterizedAttribute, parameter))
                }
                func letter(_ location: Int) -> String? {
                    var one = CFRange(location: location, length: 1)
                    guard location >= 0, let parameter = AXValueCreate(.cfRange, &one) else { return nil }
                    return parameterized(field, kAXStringForRangeParameterizedAttribute, parameter) as? String
                }
                if end > 0, let before = letter(end - 1), before != "\n", before != "\r", let r = bounds(end - 1), r.height > 0 {
                    return CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
                }
                if let r = bounds(end), r.height > 0 {
                    return CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)
                }
            }
        }
        // A caret is a sliver; Chromium answers with the whole field, which says nothing about where the caret is.
        if let markers = value(field, "AXSelectedTextMarkerRange"),
           let r = rect(parameterized(field, "AXBoundsForTextMarkerRange", markers)), r.height > 0, r.width <= 4 {
            return CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
        }
        return nil
    }

    /// Browsers built on Chromium (they draw web pages with the same engine as Electron apps).
    private static func isChromium(_ bundleID: String) -> Bool {
        ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
         "com.vivaldi.Vivaldi", "com.operasoftware.Opera"].contains { bundleID.hasPrefix($0) }
    }

    static func enableWebAccessibility(_ app: AXUIElement, pid: pid_t) {
        lock.lock()
        let isNew = webAccessibilityEnabled.insert(pid).inserted
        lock.unlock()
        if isNew {
            AXUIElementSetMessagingTimeout(app, 0.3)
            // Electron apps take AXManualAccessibility; Chrome itself only the older AXEnhancedUserInterface.
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .attributeUnsupported,
               NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(isChromium) == true {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }
    }
}

extension Accessibility {
    /// Text selected in the frontmost app outside a text field (a web page, a message, a document) and where it
    /// sits on screen. Native views give it as AXSelectedText; web views (browsers, Electron apps) through text markers.
    static func selectedText(frontmost pid: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier)
        -> (selected: SelectedText, bounds: CGRect)? {
        guard isTrusted, let pid, pid != getpid(), pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        enableWebAccessibility(app, pid: pid)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "the app"
        let window = (element(focused, kAXWindowAttribute) ?? element(app, kAXFocusedWindowAttribute))
            .flatMap { string($0, kAXTitleAttribute) } ?? ""
        func usable(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2,
                  text.contains(where: \.isLetter) else { return nil }
            return String(text.prefix(8000))
        }
        guard string(focused, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return nil }

        // Web content keeps its selection on the page, so look from the focused element up to its web area.
        var candidates = [focused]
        var node = focused
        for _ in 0..<12 {
            guard string(node, kAXRoleAttribute) != "AXWebArea", let parent = element(node, kAXParentAttribute) else { break }
            candidates.append(parent)
            node = parent
        }
        let markerSelection = candidates.lazy.compactMap { candidate -> (AXUIElement, CFTypeRef)? in
            value(candidate, "AXSelectedTextMarkerRange").map { (candidate, $0) }
        }.first

        // Native views say the selected text outright; web views only through the markers.
        var text = usable(string(focused, kAXSelectedTextAttribute))
        if text == nil, let (owner, markers) = markerSelection {
            text = usable(parameterized(owner, "AXStringForTextMarkerRange", markers) as? String)
        }
        guard let text else { return nil }

        let bounds = value(focused, kAXSelectedTextRangeAttribute)
            .flatMap { rect(parameterized(focused, kAXBoundsForRangeParameterizedAttribute, $0)) }
            ?? markerSelection.flatMap { rect(parameterized($0.0, "AXBoundsForTextMarkerRange", $0.1)) }
            ?? frame(of: focused)
        guard let bounds else { return nil }
        return (SelectedText(app: name, window: window, text: text), bounds)
    }

    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    /// An Accessibility rect (top-left origin) in AppKit screen coordinates; nil when empty.
    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Puts the draft into the field Scriber was opened from: bring its app forward, focus the field, paste (⌘V),
/// then read the field back to make sure the text arrived.
enum TextInserter {
    /// True once the draft is in the field (or pasted where it can't be checked); false if it couldn't be done.
    @MainActor
    static func paste(into target: TextTarget, text: String) async -> Bool {
        guard Accessibility.isTrusted else { return false }
        for _ in 0..<24 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            TimingLog.write("Insert: \(target.appName) didn't come to the front")
            return false
        }
        if !CGPreflightPostEventAccess() { TimingLog.write("Insert: no permission to send ⌘V") }
        // Being frontmost isn't the same as taking keystrokes yet; browsers and Electron apps need a moment more.
        try? await Task.sleep(nanoseconds: 180_000_000)
        // Web apps rebuild their accessibility tree; if the remembered field is gone, use whatever field has focus now.
        var field = target.element
        if Accessibility.string(field, kAXRoleAttribute) == nil,
           let current = Accessibility.focusedTextTarget(frontmost: target.pid)?.element {
            field = current
        }
        if let window = Accessibility.element(field, kAXWindowAttribute) {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        let focused = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 120_000_000)
        let target = TextTarget(element: field, pid: target.pid, appName: target.appName, frame: target.frame,
                                selectedText: target.selectedText)

        let before = Accessibility.string(target.element, kAXValueAttribute)
        TimingLog.write("Insert: \(target.appName) in front, focus \(focused == .success ? "set" : "error \(focused.rawValue)"), field text \(before.map { "\($0.count) chars" } ?? "unreadable")")
        // Watch the field, and whatever field the app says has focus in case that's a different one.
        var watched: [(AXUIElement, String)] = before.map { [(target.element, $0)] } ?? []
        if let other = Accessibility.focusedTextTarget(frontmost: target.pid)?.element, !CFEqual(other, target.element),
           let text = Accessibility.string(other, kAXValueAttribute) {
            watched.append((other, text))
        }
        postPaste()
        if await changed(watched) {
            TimingLog.write("Insert: pasted into \(target.appName)" + (watched.isEmpty ? " (can't be checked)" : ""))
            return true
        }
        // Nothing changed: the paste went nowhere. Once more, after a longer pause.
        try? await Task.sleep(nanoseconds: 250_000_000)
        AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        postPaste()
        if await changed(watched) {
            TimingLog.write("Insert: pasted into \(target.appName) on the second try")
            return true
        }
        // Last resort: put the text in through Accessibility (plain text, no formatting).
        if AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
           await changed(watched) {
            TimingLog.write("Insert: typed into \(target.appName) through Accessibility")
            return true
        }
        TimingLog.write("Insert: nothing arrived in \(target.appName)")
        return false
    }

    /// Whether any watched field's text changed within ~0.8 s. Nothing to watch (fields that don't expose
    /// their text) counts as yes.
    @MainActor
    private static func changed(_ watched: [(AXUIElement, String)]) async -> Bool {
        guard !watched.isEmpty else { return true }
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            for (element, before) in watched {
                if let now = Accessibility.string(element, kAXValueAttribute), now != before { return true }
            }
        }
        return false
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// What Whittle can be opened from in the app in front: a focused text field, or text selected anywhere.
enum FieldFocus {
    case field(TextTarget)
    case selection(SelectedText, bounds: CGRect)
}

/// Watches the focused text field and the selection, off the main thread so a slow app can't stall Whittle.
@MainActor
final class TextFieldWatcher {
    var onChange: ((FieldFocus?) -> Void)?
    private(set) var current: FieldFocus?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "scriber.fields")
    private var polling = false
    /// A selection shows its button once it has held still for one poll, so dragging doesn't flicker it.
    private var pendingSelection: (SelectedText, CGRect)?
    /// The caret at the last poll, to tell typing from a caret that has stopped.
    private var lastCaret: (field: TextTarget, caret: CGRect?)?

    var field: TextTarget? {
        if case .field(let target) = current { return target }
        return nil
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        update(nil)
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.async { [weak self] in
            let target = Accessibility.focusedTextTarget(frontmost: frontmost)
            let selection = target == nil ? Accessibility.selectedText(frontmost: frontmost) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.polling = false
                    if var target {
                        self.pendingSelection = nil
                        if let last = self.lastCaret, target.isSameField(as: last.field) {
                            target.caretMoving = target.caret != last.caret
                        }
                        self.lastCaret = (target, target.caret)
                        self.update(.field(target))
                    } else if let selection {
                        if let pending = self.pendingSelection, pending.0 == selection.selected, pending.1 == selection.bounds {
                            self.update(.selection(selection.selected, bounds: selection.bounds))
                        } else {
                            self.pendingSelection = (selection.selected, selection.bounds)
                            if case .selection = self.current { self.update(nil) }
                        }
                    } else {
                        self.pendingSelection = nil
                        self.update(nil)
                    }
                }
            }
        }
    }

    private func update(_ focus: FieldFocus?) {
        let same: Bool
        switch (focus, current) {
        case (nil, nil): same = true
        case (.field(let new), .field(let old)):
            same = new.isSameField(as: old) && new.frame == old.frame && new.caret == old.caret && new.caretMoving == old.caretMoving
        case (.selection(let new, let a), .selection(let old, let b)): same = new == old && a == b
        default: same = false
        }
        current = focus
        if !same { onChange?(focus) }
    }
}

/// The little button that opens Whittle for the focused text field or the selected text. It sits right after the
/// caret (out of the way while the caret moves) or under a selection. Dragged somewhere, it stays there for that app.
@MainActor
final class FieldButton {
    var onClick: (() -> Void)?
    private var panel: NSPanel?
    private var focus: FieldFocus?
    private var dragging = false
    /// 19 pixels at 1 point each, with 4 points around them.
    static let size: CGFloat = 27

    func show(for focus: FieldFocus) {
        self.focus = focus
        guard !dragging else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = Self.size
        var origin: CGPoint
        let area: CGRect
        switch focus {
        case .field(let target):
            area = target.frame
            if let place = FieldButtonPlaces.place(for: target.bundleID) {
                // Where the writer put it.
                origin = place.origin(field: target.frame, window: target.window)
            } else if target.caretMoving {
                panel.orderOut(nil)
                return
            } else if let caret = target.caret {
                // Right after the caret, on its line; inside the field when the line runs to its edge.
                origin = CGPoint(x: min(caret.maxX + 8, target.frame.maxX - size - 4), y: caret.midY - size / 2)
            } else {
                origin = CGPoint(x: target.frame.maxX - size - 6, y: target.frame.minY + 6)
            }
        case .selection(_, let bounds):
            // Just under the end of the selection.
            area = bounds
            origin = CGPoint(x: bounds.maxX - size / 2, y: bounds.minY - size - 4)
        }
        // Kept on the screen it's on.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(area) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size - 4)
        }
        panel.setFrame(CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: CGSize(width: size, height: size)),
                       display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Where the button is on screen; nil while hidden.
    var debugPanelFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = FieldButtonHost(rootView: FieldButtonView())
        host.onClick = { [weak self] in self?.onClick?() }
        host.onDragStart = { [weak self] in self?.dragging = true }
        host.onDragEnd = { [weak self] origin in self?.dropped(at: origin) }
        host.makeMenu = { [weak self] in self?.contextMenu() }
        panel.contentView = host
        return panel
    }

    private func dropped(at origin: CGPoint) {
        dragging = false
        guard case .field(let target) = focus, let bundleID = target.bundleID else { return }
        let place = ButtonPlace(dropped: origin, size: Self.size, field: target.frame, window: target.window)
        FieldButtonPlaces.set(place, for: bundleID)
        TimingLog.write("Button: placed in \(target.appName) at \(origin), field \(target.frame), window \(target.window.map { "\($0)" } ?? "-") → \(place)")
    }

    private func contextMenu() -> NSMenu? {
        guard case .field(let target) = focus, let bundleID = target.bundleID, FieldButtonPlaces.place(for: bundleID) != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Put Back Next to the Cursor", action: #selector(FieldButtonMenuTarget.reset(_:)), keyEquivalent: "")
        item.target = FieldButtonMenuTarget.shared
        FieldButtonMenuTarget.shared.reset = { [weak self] in
            FieldButtonPlaces.set(nil, for: bundleID)
            if let focus = self?.focus { self?.show(for: focus) }
        }
        menu.addItem(item)
        return menu
    }
}

/// Where the writer dragged the field button, per app.
enum FieldButtonPlaces {
    /// Earlier builds kept an offset from the field's corner here; those entries don't decode and are replaced on the next drag.
    private static let key = "fieldButtonPlaces"

    static func place(for bundleID: String?) -> ButtonPlace? {
        guard let bundleID, let data = UserDefaults.standard.dictionary(forKey: key)?[bundleID] as? Data else { return nil }
        return try? JSONDecoder().decode(ButtonPlace.self, from: data)
    }

    static func set(_ place: ButtonPlace?, for bundleID: String) {
        var places = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        places[bundleID] = place.flatMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(places, forKey: key)
    }
}

@MainActor
private final class FieldButtonMenuTarget: NSObject {
    static let shared = FieldButtonMenuTarget()
    var reset: (() -> Void)?
    @objc func reset(_ sender: Any?) { reset?() }
}

/// The button's view: a click opens Whittle, a drag moves it, a right-click offers to put it back.
/// Clicks land even though Whittle isn't the active app.
private final class FieldButtonHost: NSHostingView<FieldButtonView> {
    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?
    var makeMenu: (() -> NSMenu?)?
    private var press: (mouse: CGPoint, origin: CGPoint)?
    private var moved = false

    required init(rootView: FieldButtonView) {
        super.init(rootView: rootView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Write with Whittle")
        toolTip = "Write with Whittle (⌃⌥S) · drag to move"
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks and drags come here, not to SwiftUI's views inside.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        press = (NSEvent.mouseLocation, window.frame.origin)
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, let window else { return }
        let mouse = NSEvent.mouseLocation
        let delta = CGPoint(x: mouse.x - press.mouse.x, y: mouse.y - press.mouse.y)
        if !moved, hypot(delta.x, delta.y) < 3 { return }
        if !moved {
            moved = true
            onDragStart?()
            NSCursor.closedHand.push()
        }
        window.setFrameOrigin(CGPoint(x: (press.origin.x + delta.x).rounded(), y: (press.origin.y + delta.y).rounded()))
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        if moved {
            NSCursor.pop()
            if let window { onDragEnd?(window.frame.origin) }
        } else if press != nil {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

private struct FieldButtonView: View {
    @State private var hovering = false

    var body: some View {
        PixelGlyph(color: .white, pixel: 1)
            .frame(width: FieldButton.size, height: FieldButton.size)
            .background(Theme.accent.opacity(hovering ? 1 : 0.88), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
