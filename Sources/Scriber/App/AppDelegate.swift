import AppKit
import SwiftUI
import Carbon
import ServiceManagement
import ScriberCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let session = WritingSession()
    private var panelController: WritingPanelController?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private let fieldWatcher = TextFieldWatcher()
    private let fieldButton = FieldButton()

    /// The little Scriber button in focused text fields of other apps.
    private var showsFieldButton: Bool {
        get { UserDefaults.standard.object(forKey: "fieldButton") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fieldButton") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ContextStore.shared.ensureSeeded()
        installMainMenu()
        setupMenuBar()
        registerHotKey()
        panelController = WritingPanelController(session: session)
        session.prepareBackends()
        setUpFieldButton()
        NSLog("Whittle launched. Hotkey: ⌃⌥S (Control-Option-S).")
        restoreOpenAtLogin()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterHotKey()
        session.stop()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = PixelArt.menuBarImage()
            button.toolTip = "Whittle"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // MARK: - Button in other apps' text fields

    private func setUpFieldButton() {
        if !Accessibility.isTrusted, !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            Accessibility.requestTrust()
        }
        fieldButton.onClick = { [weak self] in
            guard let self else { return }
            self.fieldButton.hide()
            switch self.fieldWatcher.current {
            case .field(let target): self.panelController?.present(field: target)
            case .selection(let selected, _): self.panelController?.present(selection: selected)
            case nil: self.panelController?.present()
            }
        }
        // Scriber's own window is never a target, so the button only shows while another app is in front.
        fieldWatcher.onChange = { [weak self] focus in
            guard let self else { return }
            if let focus, self.showsFieldButton {
                self.fieldButton.show(for: focus)
            } else {
                self.fieldButton.hide()
            }
        }
        panelController?.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            if visible {
                self.fieldButton.hide()
            } else if let focus = self.fieldWatcher.current, self.showsFieldButton {
                self.fieldButton.show(for: focus)
            }
        }
        if showsFieldButton { fieldWatcher.start() }
    }

    /// Clicking the Dock icon opens the writing window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.present()
        return false
    }

    @objc private func toggleDockIcon() {
        let shows = !(UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true)
        UserDefaults.standard.set(shows, forKey: "showInDock")
        NSApp.setActivationPolicy(shows ? .regular : .accessory)
        if panelController?.isVisible == true { NSApp.activate(ignoringOtherApps: true) }
    }

    @objc private func toggleListenOnOpen() {
        UserDefaults.standard.set(!WritingSession.listensOnOpen, forKey: WritingSession.listenOnOpenKey)
    }

    @objc private func toggleFieldButton() {
        showsFieldButton.toggle()
        if showsFieldButton { fieldWatcher.start() } else { fieldWatcher.stop(); fieldButton.hide() }
    }

    /// Open at Login is remembered, so it comes back after the app is reinstalled or renamed.
    private func restoreOpenAtLogin() {
        guard UserDefaults.standard.bool(forKey: "openAtLogin"), SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(false, forKey: "openAtLogin")
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "openAtLogin")
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nIt works when Whittle runs from /Applications (scripts/install.sh)."
            alert.runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        Accessibility.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenSettings() {
        ScreenReader.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Rebuilt each time it opens, so the editor checkmark is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The quill and wordmark on top; the word follows the menu's own light or dark text colour.
        let brand = NSMenuItem()
        let lockup = NSHostingView(rootView: BrandLockup(word: .primary).padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 4))
        lockup.frame.size = lockup.fittingSize
        brand.view = lockup
        menu.addItem(brand)
        menu.addItem(NSMenuItem(title: "Open Writing Window", action: #selector(openWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let editor = NSMenuItem(title: "Editor", action: nil, keyEquivalent: "")
        let engines = NSMenu()
        for engine in EditorEngine.allCases {
            let entry = NSMenuItem(title: engine.title, action: #selector(chooseEngine(_:)), keyEquivalent: "")
            entry.representedObject = engine.rawValue
            entry.state = session.engine == engine ? .on : .off
            entry.target = self
            engines.addItem(entry)
        }
        engines.addItem(NSMenuItem.separator())
        let fast = NSMenuItem(title: "Fast Edits (GPT-6 Luna)", action: #selector(toggleFastEdits), keyEquivalent: "")
        fast.state = WritingSession.alwaysThorough ? .off : .on
        fast.target = self
        fast.toolTip = "Everyday edits use the fast model; reworking the whole draft and Structure and Review use the thorough one"
        engines.addItem(fast)
        editor.submenu = engines
        menu.addItem(editor)
        menu.addItem(NSMenuItem(title: "Show Voice Command Cards", action: #selector(showCommandCards), keyEquivalent: ""))
        let listenItem = NSMenuItem(title: "Start Listening When Opened", action: #selector(toggleListenOnOpen), keyEquivalent: "")
        listenItem.state = WritingSession.listensOnOpen ? .on : .off
        menu.addItem(listenItem)
        let fieldItem = NSMenuItem(title: "Button in Text Fields", action: #selector(toggleFieldButton), keyEquivalent: "")
        fieldItem.state = showsFieldButton ? .on : .off
        menu.addItem(fieldItem)
        let dockItem = NSMenuItem(title: "Show in Dock", action: #selector(toggleDockIcon), keyEquivalent: "")
        dockItem.state = (UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true) ? .on : .off
        menu.addItem(dockItem)
        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        if !Accessibility.isTrusted {
            menu.addItem(NSMenuItem(title: "Allow Accessibility (text fields, inserting)…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        }
        if !ScreenReader.hasPermission {
            menu.addItem(NSMenuItem(title: "Allow Screen Reading (context)…", action: #selector(openScreenSettings), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Reveal Context Folder", action: #selector(revealContext), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal Logs", action: #selector(revealLogs), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let info = NSMenuItem(title: [session.speechInfo, session.modelInfo].filter { !$0.isEmpty }.joined(separator: " · "),
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Whittle", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items where entry.action != nil {
            entry.target = self
        }
    }

    /// A menu-bar app has no visible menu, but text editing shortcuts (⌘C, ⌘V, ⌘A, ⌘Z) come from one.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Whittle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        // Uppercase means Shift: "z" with a Shift mask never matches a real ⇧⌘Z.
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(NSMenuItem.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func openWindow() {
        panelController?.present()
    }

    @objc private func revealContext() {
        NSWorkspace.shared.open(ContextStore.shared.rootURL)
    }

    @objc private func revealLogs() {
        NSWorkspace.shared.open(TimingLog.directory)
    }

    @objc private func toggleFastEdits() {
        UserDefaults.standard.set(!WritingSession.alwaysThorough, forKey: "codexAlwaysThorough")
    }

    @objc private func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = EditorEngine(rawValue: raw) else { return }
        session.engine = engine
    }

    @objc private func showCommandCards() {
        UserDefaults.standard.set(false, forKey: "commandCardsDone")
        session.showCommandCards = true
        panelController?.present()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkey (Control-Option-S)

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.panelController?.toggle()
            }
            return noErr
        }, 1, &eventType, userData, &hotKeyHandler)

        var hotKeyID = EventHotKeyID(signature: OSType(0x53435242), /* SCRB */ id: 1)
        // Control + Option + S
        RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }
    }
}
