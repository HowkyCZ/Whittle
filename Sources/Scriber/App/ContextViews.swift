import SwiftUI
import AppKit
import ScriberCore

/// Above the draft: where the outside context came from and what it's about, in clay so it reads as
/// "theirs", not the draft. Shows reading, failure (with the fix) and the writer's selection too.
struct SourceBanner: View {
    var note: SourceNote
    var onClose: () -> Void
    @State private var expanded = false

    private static let fill = Theme.banner
    private static let edge = Theme.bannerEdge
    private static let label = Theme.bannerInk
    private static let text = Theme.body

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    PixelIconView(icon: note.kind == .selection ? .quote : .window, color: Self.label)
                    Text(label)
                        .font(Typeface.ui(12.5, .medium))
                        .foregroundStyle(Self.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if note.state == .reading || (note.kind == .window && note.state == .ready && note.headline.isEmpty && note.summary.isEmpty) {
                        HearingDots()
                            .scaleEffect(0.8)
                            .opacity(note.state == .reading ? 1 : 0)
                    }
                }
                content
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                PixelIconView(icon: .close, color: Self.label.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(note.kind == .selection ? "Don't use this selection" : "Don't use this window")
            .accessibilityLabel("Remove")
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Self.edge))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context: \(label)")
    }

    private var label: String {
        switch (note.kind, note.state) {
        case (.selection, _):
            return "Selected in \(note.app)" + (note.title.isEmpty ? "" : " · \(note.title)")
        case (.window, .reading):
            return "Reading \(note.app)’s window"
        case (.window, .ready):
            if !note.headline.isEmpty { return "From \(note.app) · \(note.headline)" }
            return "From \(note.app)" + (note.title.isEmpty ? "" : " · \(note.title)")
        case (.window, .failed):
            return "Couldn't read \(note.app)"
        case (.window, .needsPermission):
            return "Whittle can't see \(note.app)’s window"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch (note.kind, note.state) {
        case (.selection, _):
            Text(note.excerpt.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Typeface.ui(13.5))
                .foregroundStyle(Self.text)
                .lineSpacing(3)
                .lineLimit(expanded ? 14 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if note.excerpt.count > 220 {
                Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(Typeface.ui(12.5, .medium))
                    .foregroundStyle(Self.label)
            }
        case (.window, .ready) where !note.summary.isEmpty:
            Text(note.summary)
                .font(Typeface.ui(13.5))
                .foregroundStyle(Self.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case (.window, .failed(let reason)):
            Text(reason)
                .font(Typeface.ui(13))
                .foregroundStyle(Self.text.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        case (.window, .needsPermission):
            HStack(spacing: 10) {
                Text("Allow Screen Recording so the editor knows what you're replying to.")
                    .font(Typeface.ui(13))
                    .foregroundStyle(Self.text.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    ScreenReader.requestPermission()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .buttonStyle(.plain)
                .font(Typeface.ui(12.5, .medium))
                .foregroundStyle(Self.label)
            }
        default:
            EmptyView()
        }
    }
}

/// The context folder's files, ticked when this draft uses them, like a menu.
struct ContextPicker: View {
    static let width: CGFloat = 280
    @ObservedObject var session: WritingSession
    var addFromElsewhere: () -> Void
    @State private var files: [URL] = []

    var body: some View {
        let store = ContextStore.shared
        VStack(alignment: .leading, spacing: 0) {
            Text("Context for this draft")
                .font(Typeface.ui(12, .medium))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)
            if files.isEmpty {
                Text("Put Markdown files in the context folder (about you, your projects, how you write) and pick them here.")
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(files, id: \.self) { url in
                            let using = session.isUsing(url)
                            let empty = !store.hasContent(url)
                            MenuRow(action: { session.toggleContext(url) }) { highlighted in
                                HStack(spacing: 9) {
                                    PixelIconView(icon: .check, color: highlighted ? .white : Theme.ink)
                                        .opacity(using ? 1 : 0)
                                    Text(store.relativeName(url))
                                        .font(Typeface.ui(13))
                                        .foregroundStyle(highlighted ? Color.white : Theme.ink)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    if empty {
                                        Text("empty")
                                            .font(Typeface.ui(12))
                                            .foregroundStyle(highlighted ? Color.white.opacity(0.7) : Theme.muted)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .frame(height: 30)
                            }
                            .help(empty ? "Nothing in this file yet; fill it in to use it" : store.url(store.relativeName(url)).path)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
            MenuRow(action: addFromElsewhere) { highlighted in
                row("Add a file from elsewhere…", icon: .plus, highlighted: highlighted)
            }
            MenuRow(action: { NSWorkspace.shared.open(store.rootURL) }) { highlighted in
                row("Open the context folder", icon: .folder, highlighted: highlighted)
            }
        }
        .padding(5)
        .frame(width: Self.width)
        .modifier(PopoverCard())
        .onAppear { files = store.files() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context files")
    }

    private func row(_ title: String, icon: PixelIcon, highlighted: Bool) -> some View {
        HStack(spacing: 9) {
            PixelIconView(icon: icon, color: highlighted ? .white : Theme.secondary)
            Text(title)
                .font(Typeface.ui(13))
                .foregroundStyle(highlighted ? Color.white : Theme.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
    }
}
