# Focus restore notes

## Approach used

1. Before the writing panel becomes key, capture `NSWorkspace.shared.frontmostApplication` (pid, bundle id, name).
2. On **Done**: copy document to the general pasteboard, hide the panel, then:
   - `NSApp.yieldActivation(to: previous)` (macOS 14+)
   - `previous.activate(options: [.activateAllWindows])`
3. If restore fails (nil pid / app quit / activate returns false), show an alert: text is on the clipboard.

## Expected reliability

| Target | Expectation |
|---|---|
| Native AppKit/SwiftUI apps (Notes, TextEdit) | Usually restores |
| Terminal, Xcode | Usually restores |
| Chrome / Electron (Gmail, Notion) | Flaky — window may return without prior field focus |
| Full-screen Space changes | May fail |

**Clipboard is the source of truth.** Focus restore is best-effort.

## What was not done (v1)

- No Accessibility `AXRaise` dance beyond `NSRunningApplication.activate`
- No keystroke injection / Cmd-V automation
- No selection replace
