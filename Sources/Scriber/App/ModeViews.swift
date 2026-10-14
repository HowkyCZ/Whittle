import SwiftUI
import ScriberCore

extension WritingMode {
    var icon: PixelIcon {
        switch self {
        case .write: return .quill
        case .structure: return .list
        case .review: return .bubble
        }
    }
}

// MARK: - Mode dropdown

/// The current mode as icon, name and chevron, like Google Docs' "Editing" control.
struct ModeButton: View {
    var mode: WritingMode
    var isOpen: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                PixelIconView(icon: mode.icon, color: Theme.ink)
                Text(mode.title)
                    .font(Typeface.ui(12.5, .medium))
                    .foregroundStyle(Theme.ink)
                PixelIconView(icon: .chevron, color: Theme.secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(height: 28)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isOpen ? Theme.ink : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Mode")
        .accessibilityLabel("Mode: \(mode.title)")
    }
}

/// The modes with what each is for; the current one is ticked.
struct ModeMenu: View {
    static let width: CGFloat = 270
    var current: WritingMode
    var choose: (WritingMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(WritingMode.allCases) { mode in
                MenuRow(action: { choose(mode) }) { highlighted in
                    HStack(alignment: .top, spacing: 12) {
                        PixelIconView(icon: mode.icon, color: highlighted ? .white : Theme.ink)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .font(Typeface.ui(13, .medium))
                                .foregroundStyle(highlighted ? Color.white : Theme.ink)
                            Text(mode.summary)
                                .font(Typeface.ui(12))
                                .foregroundStyle(highlighted ? Color.white.opacity(0.75) : Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        if mode == current {
                            PixelIconView(icon: .check, color: highlighted ? .white : Theme.ink)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .modifier(PopoverCard(radius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }
}

/// A row in a popover. Under the pointer it fills solid dark with white content, like a native menu item;
/// `content` gets whether it's highlighted so it can switch its colours.
struct MenuRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: (_ highlighted: Bool) -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content(hovering)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Theme.ink : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// White card with a crisp edge, for things that float over the window. The shadow stays tight so the
/// edge reads clearly on the warm grey of Review.
struct PopoverCard: ViewModifier {
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.control))
            .shadow(color: Theme.ink.opacity(0.10), radius: 5, y: 3)
    }
}

/// Dark, light and quiet buttons used across the modes.
struct ModeActionButton: View {
    enum Style { case dark, outline, quiet }
    var title: String
    var style: Style
    var height: CGFloat = 30
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.ui(13, style == .dark ? .medium : .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, style == .quiet ? 8 : 13)
                .frame(height: height)
                .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if style == .outline {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.control)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var foreground: Color {
        guard enabled else { return Theme.muted }
        switch style {
        case .dark: return .white
        case .outline: return Theme.controlText
        case .quiet: return Theme.secondary
        }
    }

    private var background: Color {
        switch style {
        case .dark: return enabled ? Theme.ink : Theme.disabledFill
        case .outline: return Theme.surface
        case .quiet: return .clear
        }
    }
}

// MARK: - Structure

/// The plan: numbered sections with their why and must-say points. Never prose.
struct OutlineView: View {
    @ObservedObject var session: WritingSession

    var body: some View {
        let outline = session.outline
        ScrollView {
            if outline.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(outline.sections.enumerated()), id: \.element.id) { index, section in
                        SectionRow(number: index + 1, section: section, outline: outline,
                                   fresh: session.freshSections.contains(section.id))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }
        }
        .scrollIndicators(.automatic)
        .animation(.easeOut(duration: 0.22), value: outline.sections.map(\.id))
        .animation(.easeOut(duration: 0.6), value: session.freshSections)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if session.outlineBusy > 0 {
                HearingDots()
                Text("Reading the draft")
                    .font(Typeface.ui(13))
                    .foregroundStyle(Theme.muted)
            } else {
                Text("No sections yet")
                    .font(Typeface.ui(14, .medium))
                    .foregroundStyle(Theme.ink)
                Text("Say what the piece needs to cover, like “start by thanking him, then explain who we are, then the ask”.")
                    .font(Typeface.ui(13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

private struct SectionRow: View {
    var number: Int
    var section: OutlineSection
    var outline: Outline
    var fresh: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            numberBadge
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 8) {
                Text(section.title)
                    .font(Typeface.ui(15, .semibold))
                    .foregroundStyle(Theme.ink)
                if !section.why.isEmpty {
                    Text(section.why)
                        .font(Typeface.ui(13))
                        .foregroundStyle(Theme.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !section.points.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(section.points) { point in
                            let status = outline.status(of: point, in: section)
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                PointBox(status: status)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                                Text(point.text)
                                    .font(Typeface.ui(14))
                                    .foregroundStyle(status == .covered ? Theme.secondary : Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fresh ? Theme.accent.opacity(0.1) : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(fresh ? Theme.accent.opacity(0.35) : Theme.border))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
    }

    /// Filled dark once written; a dashed ring until then.
    private var numberBadge: some View {
        ZStack {
            if section.isWritten {
                Circle().fill(Theme.ink)
            } else {
                Circle().strokeBorder(Theme.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
            Text("\(number)")
                .font(Typeface.ui(12.5, .medium))
                .foregroundStyle(section.isWritten ? Color.white : Theme.muted)
        }
        .frame(width: 28, height: 28)
        .help(section.isWritten ? "Written" : "Not written yet")
    }
}

/// Ticked by the model, never by hand: green when the text says it, empty until written, orange when written without it.
private struct PointBox: View {
    var status: PointStatus

    var body: some View {
        ZStack {
            switch status {
            case .covered:
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.unchanged)
                PixelIconView(icon: .check, color: .white)
            case .notWritten:
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.emptyBox, lineWidth: 1.5)
            case .missing:
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.accent.opacity(0.15))
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
        .frame(width: 16, height: 16)
        .help(status == .covered ? "In the text" : status == .missing ? "Written, but the text doesn't say this yet" : "Not written yet")
    }
}

// MARK: - Review

/// The comments, newest agent results merging in as they arrive.
struct ReviewColumn: View {
    @ObservedObject var session: WritingSession
    @Binding var agentsOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(Typeface.ui(15, .semibold))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 4) {
                    ForEach(commentingAgents) { agent in
                        Circle().fill(Theme.agent(agent.color)).frame(width: 10, height: 10)
                    }
                }
                Spacer(minLength: 0)
                Button { agentsOpen.toggle() } label: {
                    PixelIconView(icon: .sliders, color: agentsOpen ? .white : Theme.secondary)
                        .frame(width: 30, height: 30)
                        .background(agentsOpen ? Theme.ink : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Agents")
                .accessibilityLabel("Agents")
                .anchorPreference(key: AgentsButtonKey.self, value: .bounds) { $0 }
            }
            .padding(.leading, 6)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(reading) { agent in
                        ReadingRow(agent: agent)
                    }
                    ForEach(session.comments) { comment in
                        CommentRow(session: session, comment: comment,
                                   agent: session.agent(for: comment),
                                   selected: session.selectedComment == comment.id)
                    }
                    if session.comments.isEmpty, session.runningAgents.isEmpty {
                        Text(emptyText)
                            .font(Typeface.ui(13))
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(2)
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.18), value: session.comments)
        .animation(.easeOut(duration: 0.18), value: session.selectedComment)
    }

    private var title: String {
        let n = session.comments.count
        return n == 1 ? "1 comment" : "\(n) comments"
    }

    private var emptyText: String {
        if session.documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write something first, then the agents can read it." }
        if !session.agents.contains(where: \.enabled) { return "Every agent is off. Turn some on in the agent settings." }
        return "No comments. Nothing in their briefs needed saying."
    }

    private var commentingAgents: [ReviewAgent] {
        let ids = Set(session.comments.map(\.agentID))
        return session.agents.filter { ids.contains($0.id) }
    }

    private var reading: [ReviewAgent] {
        session.agents.filter { session.runningAgents.contains($0.id) }
    }
}

struct AgentsButtonKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// An agent still reading the draft.
private struct ReadingRow: View {
    var agent: ReviewAgent
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.agent(agent.color))
                .frame(width: 12, height: 12)
                .opacity(pulse ? 0.35 : 1)
            Text("\(agent.name) is reading")
                .font(Typeface.ui(13))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct CommentRow: View {
    @ObservedObject var session: WritingSession
    var comment: ReviewComment
    var agent: ReviewAgent?
    var selected: Bool

    var body: some View {
        let expanded = selected && comment.state != .talking
        VStack(alignment: .leading, spacing: expanded ? 12 : 6) {
            HStack(spacing: 10) {
                Circle().fill(Theme.agent(agent?.color ?? "#6C6975")).frame(width: 12, height: 12)
                Text(agent?.name ?? "Agent")
                    .font(Typeface.ui(13, .medium))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                status
            }
            Text(comment.message)
                .font(Typeface.ui(expanded ? 14 : 13))
                .foregroundStyle(expanded ? Theme.ink : Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if expanded {
                HStack(spacing: 8) {
                    ModeActionButton(title: comment.state == .approved ? "Unapprove" : "Approve",
                                     style: comment.state == .approved ? .outline : .dark) {
                        session.toggleApproval(comment.id)
                    }
                    ModeActionButton(title: "Reply", style: .outline) { session.startConversation(comment.id) }
                    Spacer(minLength: 0)
                    ModeActionButton(title: "Dismiss", style: .quiet) { session.dismissComment(comment.id) }
                }
            }
        }
        .padding(14)
        .background {
            if selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface) }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.agent(agent?.color ?? "#6C6975"), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { session.selectComment(comment.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent?.name ?? "Agent"): \(comment.message)")
    }

    @ViewBuilder
    private var status: some View {
        switch comment.state {
        case .approved, .concluded:
            HStack(spacing: 4) {
                PixelIconView(icon: .check, color: Theme.unchanged)
                Text(comment.state == .approved ? "Approved" : "Agreed")
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(Theme.unchanged)
            }
        case .talking:
            Text("Talking")
                .font(Typeface.ui(12.5))
                .foregroundStyle(Theme.muted)
        case .open:
            EmptyView()
        }
    }
}

/// The conversation with one agent, above the voice box.
struct ConversationCard: View {
    @ObservedObject var session: WritingSession
    var comment: ReviewComment

    var body: some View {
        let agent = session.agent(for: comment)
        let color = Theme.agent(agent?.color ?? "#6C6975")
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        agentLine(comment.message, color: color)
                        ForEach(Array(comment.thread.enumerated()), id: \.offset) { _, message in
                            if message.from == .writer {
                                Text(message.text)
                                    .font(Typeface.ui(14))
                                    .foregroundStyle(Theme.dockText)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .padding(.leading, 26)
                            } else {
                                agentLine(message.text, color: color)
                            }
                        }
                        if session.agentIsReplying {
                            HStack(spacing: 14) {
                                Circle().fill(color).frame(width: 12, height: 12)
                                HearingDots()
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: comment.thread.count) { proxy.scrollTo("end") }
            }
            HStack(spacing: 8) {
                ModeActionButton(title: "Send to editor", style: .dark, enabled: !comment.conclusion.isEmpty && !session.agentIsReplying) {
                    session.concludeConversation()
                }
                .help(comment.conclusion.isEmpty ? "Nothing to change yet" : comment.conclusion)
                ModeActionButton(title: "Dismiss", style: .quiet) { session.dismissConversation() }
            }
            .padding(.leading, 26)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation with \(agent?.name ?? "the agent")")
    }

    private func agentLine(_ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Circle().fill(color)
                .frame(width: 12, height: 12)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text)
                .font(Typeface.ui(14))
                .foregroundStyle(Theme.dockText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Which agents read the draft, plus adding one and running them again.
struct AgentsPopover: View {
    static let width: CGFloat = 330
    @ObservedObject var session: WritingSession
    var close: () -> Void
    @State private var adding = false
    @State private var name = ""
    @State private var brief = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.agents) { agent in
                HStack(spacing: 14) {
                    Circle().fill(Theme.agent(agent.color)).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                            .font(Typeface.ui(13.5, .medium))
                            .foregroundStyle(Theme.ink)
                        Text(agent.brief)
                            .font(Typeface.ui(12.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(get: { agent.enabled }, set: { session.setAgent(agent.id, enabled: $0) }))
                        .toggleStyle(.switch)
                        .tint(Theme.ink)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel(agent.name)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 8).padding(.top, 4)
            if adding {
                VStack(alignment: .leading, spacing: 8) {
                    field("Name", text: $name)
                    field("What it looks for", text: $brief)
                    HStack {
                        ModeActionButton(title: "Cancel", style: .quiet) { adding = false }
                        Spacer(minLength: 0)
                        ModeActionButton(title: "Add", style: .dark, enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                            session.addAgent(name: name, brief: brief)
                            name = ""
                            brief = ""
                            adding = false
                        }
                    }
                }
                .padding(12)
            } else {
                HStack {
                    ModeActionButton(title: "Add agent", style: .quiet) { adding = true }
                    Spacer(minLength: 0)
                    ModeActionButton(title: "Run again", style: .dark, enabled: session.agents.contains(where: \.enabled)) {
                        close()
                        session.runReview()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .modifier(PopoverCard(radius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Typeface.ui(13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
