import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScriberCore

struct WritingPanelView: View {
    @ObservedObject var session: WritingSession
    var onDone: () -> Void
    var onDiscard: () -> Void

    @State private var openChip: ContextItem.ID?
    @State private var modeMenuOpen = false
    @State private var agentsOpen = false
    @State private var pickerOpen = false
    /// The send animation: the sent words lift out of the voice box while Send flashes clay.
    @State private var ghost: SentEcho?
    @State private var ghostLift = false
    @State private var sendFlash = false
    @State private var toast: VoiceToast?

    var body: some View {
        content
            .ignoresSafeArea(edges: .top)
            .background(session.mode == .review ? Theme.reviewChrome : Theme.background)
            .foregroundStyle(Theme.ink)
            .environment(\.colorScheme, .light)
            .frame(minWidth: 520, minHeight: 600)
            .overlayPreferenceValue(ChipBoundsKey.self) { anchors in
                contextPopover(anchors)
            }
            .overlayPreferenceValue(ModeButtonKey.self) { anchor in
                modeMenu(anchor)
            }
            .overlayPreferenceValue(AgentsButtonKey.self) { anchor in
                agentsPopover(anchor)
            }
            .overlayPreferenceValue(PickerButtonKey.self) { anchor in
                contextPicker(anchor)
            }
            .background(escapeKey)
            .background(dictateKey)
            .animation(.easeOut(duration: 0.18), value: session.answer)
            .animation(.easeOut(duration: 0.18), value: showsCommandCards)
            .animation(.easeOut(duration: 0.18), value: session.talkingTo)
            .animation(.easeOut(duration: 0.15), value: session.dictation != nil)
            .animation(.easeOut(duration: 0.12), value: modeMenuOpen)
            .animation(.easeOut(duration: 0.12), value: agentsOpen)
            .animation(.easeOut(duration: 0.12), value: pickerOpen)
            .animation(.easeOut(duration: 0.2), value: session.source)
    }

    @ViewBuilder
    private var content: some View {
        switch session.mode {
        case .write: writeLayout
        case .structure: structureLayout
        case .review: reviewLayout
        }
    }

    private var writeLayout: some View {
        VStack(spacing: 0) {
            header(height: 46, withMode: false)
            chips
            if let source = session.source {
                SourceBanner(note: source, onClose: session.clearSource)
                    .padding(.leading, DraftLayout.textLeft - 14)
                    .padding(.trailing, DraftLayout.textRight - 14)
                    .padding(.top, 16)
                    .transition(.opacity)
            }
            DraftEditor(session: session, onEscape: handleEscape)
                .frame(maxHeight: .infinity)
            if showsCommandCards {
                commandCards
            }
            if let answer = session.answer {
                answerCard(answer)
            }
            voiceBox
            footer
        }
    }

    /// The plan instead of the text; the voice edits sections and points.
    private var structureLayout: some View {
        VStack(spacing: 0) {
            header(height: 52, withMode: true)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            OutlineView(session: session)
                .frame(maxHeight: .infinity)
            if let answer = session.answer {
                answerCard(answer)
            }
            voiceBox
            structureFooter
        }
    }

    /// Wider, warm grey, the draft on a white sheet and the comments beside it.
    private var reviewLayout: some View {
        VStack(spacing: 0) {
            header(height: 52, withMode: true)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    DraftEditor(session: session, onEscape: handleEscape)
                        .frame(maxHeight: .infinity)
                    if let id = session.talkingTo, let comment = session.comments.first(where: { $0.id == id }) {
                        ConversationCard(session: session, comment: comment)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                    if let answer = session.answer {
                        answerCard(answer)
                    }
                    voiceBox
                        .padding(.bottom, 12)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                ReviewColumn(session: session, agentsOpen: $agentsOpen)
                    .frame(width: 320)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            reviewFooter
        }
    }

    // MARK: Header

    /// The title; in Structure and Review the mode dropdown sits at the right.
    private func header(height: CGFloat, withMode: Bool) -> some View {
        headerTitle
            .padding(.horizontal, 96)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .trailing) {
                if withMode {
                    modeButton
                        .padding(.trailing, 12)
                }
            }
    }

    /// The draft's title once it has one; before that, the quill and the wordmark.
    @ViewBuilder
    private var headerTitle: some View {
        let from = session.sourceAppName.map { "from \($0)" }
        if session.documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .bottom, spacing: 8) {
                BrandLockup()
                if let from {
                    Text(from)
                        .font(Typeface.ui(13))
                        .foregroundStyle(Theme.muted)
                        .padding(.bottom, 1)
                }
            }
        } else {
            (Text(session.title).font(Typeface.ui(13, .semibold)).foregroundStyle(Theme.ink)
                + Text(from.map { "  \($0)" } ?? "").font(Typeface.ui(13)).foregroundStyle(Theme.muted))
                .lineLimit(1)
        }
    }

    // MARK: Modes

    private var modeButton: some View {
        ModeButton(mode: session.mode, isOpen: modeMenuOpen) {
            agentsOpen = false
            openChip = nil
            modeMenuOpen.toggle()
        }
        .anchorPreference(key: ModeButtonKey.self, value: .bounds) { $0 }
    }

    @ViewBuilder
    private func modeMenu(_ anchor: Anchor<CGRect>?) -> some View {
        if modeMenuOpen, let anchor {
            GeometryReader { geo in
                let button = geo[anchor]
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .onTapGesture { modeMenuOpen = false }
                    ModeMenu(current: session.mode) { mode in
                        modeMenuOpen = false
                        session.switchMode(to: mode)
                    }
                    .offset(x: max(12, button.maxX - ModeMenu.width), y: button.maxY + 6)
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func agentsPopover(_ anchor: Anchor<CGRect>?) -> some View {
        if agentsOpen, session.mode == .review, let anchor {
            GeometryReader { geo in
                let button = geo[anchor]
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .onTapGesture { agentsOpen = false }
                    AgentsPopover(session: session) { agentsOpen = false }
                        .offset(x: button.maxX - AgentsPopover.width, y: button.maxY + 6)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Context chips

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(session.contextItems.filter { !$0.isSource }) { item in
                let isOpen = openChip == item.id
                Button {
                    openChip = isOpen ? nil : item.id
                } label: {
                    Text(item.name)
                        .font(Typeface.ui(12))
                        .foregroundStyle(isOpen ? Color.white : Theme.chipText)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(isOpen ? Theme.ink : Theme.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(item.title)
                .anchorPreference(key: ChipBoundsKey.self, value: .bounds) { [item.id: $0] }
            }
            Button {
                openChip = nil
                modeMenuOpen = false
                pickerOpen.toggle()
            } label: {
                PixelIconView(icon: .plus, color: pickerOpen ? .white : Theme.secondary)
                    .frame(width: 26, height: 26)
                    .background(pickerOpen ? Theme.ink : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose context files")
            .accessibilityLabel("Choose context files")
            .anchorPreference(key: PickerButtonKey.self, value: .bounds) { $0 }
            Spacer(minLength: 0)
            modeButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    @ViewBuilder
    private func contextPopover(_ anchors: [ContextItem.ID: Anchor<CGRect>]) -> some View {
        if let id = openChip, let anchor = anchors[id], let item = session.contextItems.first(where: { $0.id == id }) {
            GeometryReader { geo in
                let chip = geo[anchor]
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .onTapGesture { openChip = nil }
                    ContextPopover(
                        item: item,
                        onEdit: item.url.map { url in { NSWorkspace.shared.open(url) } },
                        onReveal: item.url.map { url in { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
                        onRemove: {
                            openChip = nil
                            session.removeContext(item)
                        }
                    )
                    .offset(x: min(chip.minX, geo.size.width - ContextPopover.width - 12), y: chip.maxY + 6)
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func contextPicker(_ anchor: Anchor<CGRect>?) -> some View {
        if pickerOpen, session.mode == .write, let anchor {
            GeometryReader { geo in
                let button = geo[anchor]
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .onTapGesture { pickerOpen = false }
                    ContextPicker(session: session, addFromElsewhere: {
                        pickerOpen = false
                        addContext()
                    })
                    .offset(x: min(button.minX, geo.size.width - ContextPicker.width - 12), y: button.maxY + 6)
                }
            }
            .transition(.opacity)
        }
    }

    private func addContext() {
        let panel = NSOpenPanel()
        panel.title = "Add context"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = ContextStore.shared.rootURL
        panel.level = .modalPanel
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(session.addContext)
    }

    // MARK: Command cards

    private var showsCommandCards: Bool {
        session.showCommandCards && session.documentText.isEmpty
    }

    private var commandCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CommandCard.all) { card in
                    VStack(alignment: .leading, spacing: 8) {
                        PixelIconView(icon: card.icon, color: card.ink)
                            .frame(width: 28, height: 28)
                            .background(card.tile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text("“\(card.phrase)”")
                            .font(Typeface.ui(13, .medium))
                            .foregroundStyle(Theme.ink)
                        Text(card.meaning)
                            .font(Typeface.ui(12))
                            .foregroundStyle(Theme.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(width: 148, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 10)
        .transition(.opacity)
        .accessibilityLabel("Voice commands")
    }

    // MARK: Answer card

    private func answerCard(_ answer: AnswerCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                PixelIconView(icon: answerIcon(answer.kind), color: answerColor(answer.kind))
                Text(answer.title)
                    .font(Typeface.ui(12))
            }
            .foregroundStyle(answerColor(answer.kind))

            Text(answer.message)
                .font(Typeface.ui(14))
                .lineSpacing(3)
                .foregroundStyle(Theme.dockText)
                .lineLimit(10)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if answer.canApply {
                    Button(action: session.applySuggestion) {
                        Text("Apply")
                            .font(Typeface.ui(12.5))
                            .foregroundStyle(Theme.unchanged)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Theme.unchangedFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Make this change")
                }
                Button(action: session.dismissAnswer) {
                    Text("Dismiss")
                        .font(Typeface.ui(12.5))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.ink.opacity(0.06), radius: 12, y: 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer")
    }

    private func answerIcon(_ kind: AnswerCard.Kind) -> PixelIcon {
        switch kind {
        case .answer, .note: return .check
        case .notDone: return .minus
        case .kept: return .lock
        case .failed: return .alert
        case .outline: return .list
        }
    }

    private func answerColor(_ kind: AnswerCard.Kind) -> Color {
        switch kind {
        case .answer: return Theme.unchanged
        case .note, .notDone, .outline: return Theme.secondary
        case .kept: return Theme.exactLine
        case .failed: return Theme.error
        }
    }

    // MARK: Voice box

    @ViewBuilder
    private var voiceBox: some View {
        if session.dictation != nil {
            dictationBox
        } else {
            transcriptBox
        }
    }

    /// Word for word over the selection: orange, no commands but "okay, send", Cancel or Replace.
    private var dictationBox: some View {
        HStack(alignment: .center, spacing: 12) {
            micButton(tint: Theme.exactLine)
            Text("Word for word, replacing your selection")
                .font(Typeface.ui(14))
                .foregroundStyle(Theme.exactLine)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            voiceState
                .frame(height: 36)
            ModeActionButton(title: "Cancel", style: .quiet, height: 36) { session.cancelDictation() }
                .help("Keep the selection as it was (Esc)")
            Button(action: session.send) {
                Text("Replace")
                    .font(Typeface.ui(13, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(session.sendPending ? 0.55 : 1)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .help("Replace the selection with what you said, or say “okay, send”")
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.exactLine, lineWidth: 1.5))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictating over the selection")
    }

    private var transcriptBox: some View {
        HStack(alignment: .bottom, spacing: 12) {
            micButton()
            TranscriptEditor(session: session, placeholder: ghost == nil ? placeholder : "", onEscape: handleEscape)
                .frame(minHeight: Self.markSize)
                .overlay(alignment: .leading) { sentGhost }
            // Centred on the mark while there's one line; they stay at the bottom as the text grows.
            voiceState
                .frame(height: 36)
                .padding(.bottom, (Self.markSize - 36) / 2)
            sendButton
                .padding(.bottom, (Self.markSize - 36) / 2)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice input")
        .onChange(of: session.sentEcho) { _, echo in
            guard let echo else { return }
            ghost = echo
            ghostLift = false
            sendFlash = true
            withAnimation(.easeIn(duration: 0.5).delay(0.15)) { ghostLift = true }
            withAnimation(.easeOut(duration: 0.35).delay(0.3)) { sendFlash = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if ghost == echo { ghost = nil } }
        }
        .onChange(of: session.voiceToast) { _, new in
            guard let new else { return }
            withAnimation(.easeOut(duration: 0.15)) { toast = new }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if toast == new { withAnimation(.easeIn(duration: 0.3)) { toast = nil } }
            }
        }
    }

    /// The words that were just sent, rising and fading where the transcript was.
    @ViewBuilder
    private var sentGhost: some View {
        if let ghost {
            (Text(ghost.text).foregroundStyle(Theme.dockText)
                + Text(ghost.byVoice ? "  okay, send" : "").foregroundStyle(Theme.accent).fontWeight(.medium))
                .font(Typeface.ui(14))
                .lineSpacing(4)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: ghostLift ? -28 : 0)
                .opacity(ghostLift ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var placeholder: String {
        if session.isMicPaused { return "Microphone off. Type here, or turn it on" }
        if session.mode == .review, let id = session.talkingTo ?? session.selectedComment,
           let comment = session.comments.first(where: { $0.id == id }), let agent = session.agent(for: comment) {
            return "Reply to \(agent.name)"
        }
        switch session.status {
        case .downloadingModel: return "Getting speech recognition ready…"
        case .error(let message): return message
        default: break
        }
        if session.isCapturing { return "Hearing you…" }
        if session.isTranscribing { return "Transcribing…" }
        if session.missedSpeech { return "Didn't catch that. Say it again?" }
        return "Listening"
    }

    /// What the mic is doing right now: hearing you (bars move with your voice), transcribing, or missed it.
    @ViewBuilder
    private var voiceState: some View {
        let hasText = !session.unsentText.isEmpty
        if let toast {
            HStack(spacing: 6) {
                PixelIconView(icon: .check, color: Theme.accent)
                Text(toast.text)
                    .font(Typeface.ui(12.5, .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if session.isTranscribing {
            HearingDots()
                .help("Transcribing")
                .accessibilityLabel("Transcribing")
        } else if session.missedSpeech, hasText {
            Text("Didn't catch that")
                .font(Typeface.ui(12))
                .foregroundStyle(Theme.muted)
                .transition(.opacity)
        }
    }

    /// The pixel mark: the mic whose sound lines follow your voice, the quill while the editor writes,
    /// the crossed-out mic when muted. Click to mute or unmute.
    private func micButton(tint: Color = Theme.accent) -> some View {
        let on = !session.isMicPaused
        let mode: PixelMarkEngine.Mode = !on ? .muted : (session.isBusy ? .writing : .listening)
        let label = !on ? "Microphone muted, click to turn on"
            : (session.isWorking ? "Writing. Microphone on, click to mute" : "Microphone on, click to mute")
        return Button(action: session.toggleMicPause) {
            PixelMark(mode: mode, levels: on ? session.micBands : [], color: on ? .white : Theme.muted, pixel: 1.5)
                .frame(width: Self.markSize, height: Self.markSize)
                .background(on ? tint : Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The tile; the 19-pixel art at 1.5 points per pixel leaves about 11 points around it.
    static let markSize: CGFloat = 50

    private var sendButton: some View {
        let ready = !session.unsentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !session.liveWords.isEmpty || session.isCapturing
        let waiting = session.sendPending
        let lit = ready || waiting || sendFlash
        return Button(action: session.send) {
            Text("Send")
                .font(Typeface.ui(13, .medium))
                .foregroundStyle(lit ? Color.white : Theme.muted)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(sendFlash ? Theme.accent : (lit ? Theme.ink : Theme.disabledFill),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .scaleEffect(sendFlash ? 0.93 : 1)
                .opacity(waiting && !sendFlash ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!ready || waiting)
        .help(waiting ? "Sending once your last words are in" : "Send what you said, or say “okay, send”")
    }

    // MARK: Footer

    private var undoButton: some View {
        Button(action: session.undo) {
            HStack(spacing: 10) {
                Text("Undo")
                    .font(Typeface.ui(13))
                Keycaps(keys: ["⌘", "Z"], style: .light)
            }
            .foregroundStyle(Theme.controlText)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 34)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.control))
        }
        .buttonStyle(.plain)
        .opacity(session.canUndo ? 1 : 0)
        .disabled(!session.canUndo)
        .help(session.mode == .structure ? "Back one change to the plan" : "Back one version. Redo with ⇧⌘Z")
    }

    /// Structure: how much of the plan is written, and writing the rest.
    private var structureFooter: some View {
        let outline = session.outline
        let canWrite = !outline.unwritten.isEmpty && !session.isWorking && session.outlineBusy == 0
        return HStack(spacing: 12) {
            undoButton
            if !outline.isEmpty {
                Text("\(outline.writtenCount) of \(outline.sections.count) written")
                    .font(Typeface.ui(13))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            ModeActionButton(title: "Write the rest", style: .dark, height: 36, enabled: canWrite, action: session.writeTheRest)
                .help("Write the sections that aren't written yet, then show the text")
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
    }

    /// Review: leave without changes, or send what was approved.
    private var reviewFooter: some View {
        let count = session.commentsForEditor
        return HStack(spacing: 8) {
            ModeActionButton(title: "Back to writing", style: .outline, height: 34) { session.switchMode(to: .write) }
                .help("Leave Review; comments that weren't handled are dropped")
            Spacer(minLength: 8)
            ModeActionButton(title: count == 0 ? "Send to editor" : "Send \(count) to editor", style: .dark, height: 36,
                             enabled: count > 0 && !session.isWorking, action: session.sendReviewToEditor)
                .help("The editor makes the approved changes as one version")
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var footer: some View {
        let canFinish = !session.documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            undoButton

            Spacer(minLength: 8)

            Button(action: onDone) {
                HStack(spacing: 10) {
                    Text("Done")
                        .font(Typeface.ui(13, .medium))
                    Keycaps(keys: ["⌘", "↩"], style: canFinish ? .dark : .disabled)
                }
                .foregroundStyle(canFinish ? Color.white : Theme.muted)
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .frame(height: 36)
                .background(canFinish ? Theme.ink : Theme.disabledFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canFinish)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Copy the draft and go back")
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
    }

    // MARK: Escape

    /// Esc steps back one layer: the context popover, then the answer, then the window.
    private var escapeKey: some View {
        Button("", action: handleEscape)
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// ⌥Space anywhere in the window: dictate over the draft's selection.
    private var dictateKey: some View {
        Button("", action: session.startDictation)
            .keyboardShortcut(.space, modifiers: .option)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func handleEscape() {
        if modeMenuOpen {
            modeMenuOpen = false
        } else if pickerOpen {
            pickerOpen = false
        } else if agentsOpen {
            agentsOpen = false
        } else if openChip != nil {
            openChip = nil
        } else if session.dictation != nil {
            session.cancelDictation()
        } else if session.talkingTo != nil {
            session.talkingTo = nil
        } else if session.selectedComment != nil {
            session.selectedComment = nil
        } else if session.answer != nil {
            session.dismissAnswer()
        } else {
            onDiscard()
        }
    }
}

// MARK: - Pieces

private struct PickerButtonKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

private struct ModeButtonKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

private struct ChipBoundsKey: PreferenceKey {
    static var defaultValue: [ContextItem.ID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [ContextItem.ID: Anchor<CGRect>], nextValue: () -> [ContextItem.ID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// What a context item is and where it came from, with what you can do with it, like a menu.
private struct ContextPopover: View {
    static let width: CGFloat = 236

    var item: ContextItem
    /// Only files can be edited or shown in Finder.
    var onEdit: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Typeface.ui(13, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.origin)
                    .font(Typeface.ui(12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 10)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                if let onEdit { PopoverRow(icon: .quill, title: "Edit", action: onEdit) }
                if let onReveal { PopoverRow(icon: .folder, title: "Show in Finder", action: onReveal) }
                if onEdit != nil || onReveal != nil {
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 9)
                }
                PopoverRow(icon: .minus, title: "Remove from Draft", color: Theme.destructive, action: onRemove)
                    .help("Remove from this draft only")
            }
            .padding(5)
        }
        .frame(width: Self.width)
        .modifier(PopoverCard())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
    }
}

/// One action in a popover, highlighted under the pointer like a menu item.
private struct PopoverRow: View {
    var icon: PixelIcon
    var title: String
    var color: Color = Theme.ink
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PixelIconView(icon: icon, color: hovering ? .white : color)
                Text(title)
                    .font(Typeface.ui(13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Color.white : color)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(hovering ? color : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Shortcut keys drawn as separate caps.
struct Keycaps: View {
    enum Style { case light, dark, disabled }

    var keys: [String]
    var style: Style

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }

    private var fill: Color {
        switch style {
        case .light: return Theme.chip
        case .dark: return Color.white.opacity(0.14)
        case .disabled: return Color.white
        }
    }

    private var foreground: Color {
        switch style {
        case .light: return Theme.chipText
        case .dark: return Color.white
        case .disabled: return Theme.muted
        }
    }
}

/// Whisper is working on what was just said.
struct HearingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Theme.muted)
                        .frame(width: 4, height: 4)
                        .opacity(0.3 + 0.7 * max(0, sin((t * 2 * .pi / 1.1) - Double(i) * 0.7)))
                }
            }
        }
        .accessibilityLabel("Hearing you")
    }
}

/// The start-screen cards: each spoken command, its colour, what it does.
private struct CommandCard: Identifiable {
    var phrase: String
    var meaning: String
    var icon: PixelIcon
    var tile: Color
    var ink: Color
    var id: String { phrase }

    static let all: [CommandCard] = [
        CommandCard(phrase: "Okay, send", meaning: "Sends what you said", icon: .send,
                    tile: Theme.ink, ink: .white),
        CommandCard(phrase: "Say exactly", meaning: "Keeps your words as spoken", icon: .quote,
                    tile: Theme.exactFill, ink: Theme.exactLine),
        CommandCard(phrase: "Write it like…", meaning: "Turns your gist into prose", icon: .quill,
                    tile: Theme.gistFill, ink: Theme.gistInk),
        CommandCard(phrase: "Just answer me", meaning: "Talks without editing", icon: .bubble,
                    tile: Theme.unchangedFill, ink: Theme.unchanged),
        CommandCard(phrase: "Undo that", meaning: "Goes back one version", icon: .undo,
                    tile: Theme.chip, ink: Theme.chipText),
        CommandCard(phrase: "Scratch that", meaning: "Clears what you haven't sent", icon: .close,
                    tile: Theme.chip, ink: Theme.chipText)
    ]
}
