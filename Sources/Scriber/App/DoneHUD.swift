import AppKit
import SwiftUI

/// The pill that confirms the copy while focus goes back to the previous app.
@MainActor
final class DoneHUD {
    private let model = DoneHUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(appName: String?, over frame: NSRect?) {
        model.appName = appName
        model.restoreFailed = false
        model.inserted = false

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = DoneHUDView.size
        let origin: NSPoint
        if let frame {
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        } else {
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 120)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        scheduleHide(after: 1.6)
    }

    /// Focus didn't go back; keep the pill up longer so the paste hint is seen.
    func restoreFailed() {
        model.restoreFailed = true
        scheduleHide(after: 3)
    }

    /// The draft went straight into the field it was opened from.
    func inserted() {
        model.inserted = true
        scheduleHide(after: 1.6)
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // A new show() may have started meanwhile.
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: DoneHUDView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: DoneHUDView(model: model))
        return panel
    }
}

@MainActor
final class DoneHUDModel: ObservableObject {
    @Published var appName: String?
    @Published var restoreFailed = false
    @Published var inserted = false

    var title: String { inserted ? "Inserted" : "Copied" }

    var subtitle: String {
        guard let appName else { return "Paste with ⌘V" }
        if inserted { return "In \(appName). ⌘Z there takes it out" }
        return restoreFailed
            ? "Couldn't switch to \(appName). Paste with ⌘V"
            : "Back in \(appName). Paste with ⌘V"
    }
}

struct DoneHUDView: View {
    static let size = NSSize(width: 400, height: 88)

    @ObservedObject var model: DoneHUDModel

    var body: some View {
        HStack(spacing: 14) {
            PixelIconView(icon: .check, color: .white, pixel: 2)
                .frame(width: 48, height: 48)
                .background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(Typeface.ui(15, .medium))
                    .foregroundStyle(Theme.hudText)
                Text(model.subtitle)
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(Theme.hudSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.hud, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}
