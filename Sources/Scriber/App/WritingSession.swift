import AppKit
import AVFoundation
import Combine
import Foundation
import ScriberCore

enum SessionStatus: Equatable {
    /// Mic is off.
    case idle
    case downloadingModel(String)
    case listening
    case error(String)
}

/// Who decides what to change: ChatGPT through the Codex CLI, or the local model with spoken commands.
enum EditorEngine: String, CaseIterable {
    case chatgpt
    case local

    var title: String {
        switch self {
        case .chatgpt: return "ChatGPT (Codex)"
        case .local: return "Local model"
        }
    }
}

/// What just went to the editor; the voice box animates it away.
struct SentEcho: Equatable {
    let id = UUID()
    var text: String
    /// Sent by saying "okay, send" rather than the button or Return.
    var byVoice: Bool
}

/// A spoken command that already happened, confirmed for a moment.
struct VoiceToast: Equatable {
    let id = UUID()
    var text: String
}

/// Where the change being written is expected to land, for the working highlight.
enum WorkingPlace: Equatable {
    /// The selection, or a located passage (UTF-16 range in the draft).
    case range(NSRange)
    case paragraph(Int)
    case insert(before: Int)
    case end
}

/// The text a change just added; it glows briefly and fades.
struct ChangeFlash: Equatable {
    var after: String
    var ranges: [NSRange]
    var start: Date
}

/// The latest change to the draft, so "delete that" can find what was just added.
struct DocumentChange: Equatable {
    var after: String
    var note: String
    var changes: [ParagraphChange]
}

/// What the editor said back, above the voice box.
struct AnswerCard: Equatable {
    enum Kind: Equatable {
        /// An answer; the draft is as it was.
        case answer
        /// The draft changed and the editor added a note.
        case note
        /// Nothing changed because the request couldn't be done.
        case notDone
        /// An edit was refused because it would have changed locked wording.
        case kept
        case failed
        /// Structure mode's reply about the plan.
        case outline
    }

    var kind: Kind
    var message: String

    var title: String {
        switch kind {
        case .answer: return "Document unchanged"
        case .note: return "Changed, with a note"
        case .notDone: return "Nothing changed"
        case .kept: return "Kept your exact wording"
        case .failed: return "That didn't work"
        case .outline: return "About the outline"
        }
    }

    var canApply: Bool { kind == .answer }
}

/// Where the draft's outside context came from, shown in the banner above the draft.
struct SourceNote: Equatable {
    enum Kind: Equatable { case window, selection }
    enum State: Equatable {
        case reading
        case ready
        case failed(String)
        /// Screen Recording isn't allowed yet.
        case needsPermission
    }
    var kind: Kind
    var app: String
    var title = ""
    var state: State
    /// "Email from Tomas · Re: yesterday", from the editor; "" until it's back.
    var headline = ""
    /// One sentence on what it's about.
    var summary = ""
    /// The selected text, for a selection.
    var excerpt = ""
}

/// Something the editor reads along with the draft: a context file, the window the writer came from,
/// or text they selected.
struct ContextItem: Identifiable, Equatable {
    enum Source: Equatable {
        case file(URL)
        case screen(ScreenReader.Reading)
        case selection(SelectedText)
    }

    var source: Source
    /// Added by Scriber rather than by the writer.
    var automatic: Bool

    init(url: URL, automatic: Bool) {
        self.source = .file(url)
        self.automatic = automatic
    }

    init(screen: ScreenReader.Reading) {
        self.source = .screen(screen)
        self.automatic = true
    }

    init(selection: SelectedText) {
        self.source = .selection(selection)
        self.automatic = false
    }

    /// From outside the context folder: the window or a selection. Shown in the banner, not as a chip.
    var isSource: Bool {
        if case .file = source { return false }
        return true
    }

    var id: String {
        switch source {
        case .file(let url): return url.path
        case .screen: return "screen"
        case .selection: return "selection"
        }
    }

    var url: URL? {
        if case .file(let url) = source { return url }
        return nil
    }

    /// The chip's label.
    var name: String {
        switch source {
        case .file(let url): return url.deletingPathExtension().lastPathComponent
        case .screen(let reading): return reading.app
        case .selection(let selected): return selected.app
        }
    }

    /// The popover's heading.
    var title: String {
        switch source {
        case .file(let url): return url.lastPathComponent
        case .screen(let reading): return reading.title.isEmpty ? "\(reading.app) window" : reading.title
        case .selection(let selected): return "Selected in \(selected.app)"
        }
    }

    var fileName: String { url?.lastPathComponent ?? "" }

    var origin: String {
        switch source {
        case .file: return automatic ? "Added automatically" : "Added by you"
        case .screen(let reading): return "Read from \(reading.app) on screen"
        case .selection(let selected): return "Selected in \(selected.app)"
        }
    }
}

@MainActor
final class WritingSession: ObservableObject {
    @Published var documentText: String = ""
    @Published var status: SessionStatus = .idle

    // MARK: Voice box

    /// What was said (or typed) and not sent yet.
    @Published private(set) var unsentText = "" {
        didSet { if unsentText != oldValue { updatePointed() } }
    }
    /// The place in the draft named in what's being said ("paragraph two"), highlighted while speaking.
    @Published var pointedRange: NSRange?
    /// How each part of the unsent text reads, for the transcript highlights.
    @Published private(set) var unsentSpans: [SpeechSpan] = []
    /// The mic is picking up a voice right now.
    @Published private(set) var isCapturing = false
    /// Whisper is turning a finished clip into words.
    @Published private(set) var isTranscribing = false
    /// A clip with real speech in it came back without words; shown briefly so it can be said again.
    @Published private(set) var missedSpeech = false
    /// Words from clips still being spoken or transcribed, shown faintly after the unsent text.
    @Published private(set) var liveWords = "" {
        didSet { if liveWords != oldValue { updatePointed() } }
    }
    /// Send was pressed; it goes as soon as everything said before the press is transcribed.
    @Published private(set) var sendPending = false
    /// What just went to the editor, for the send animation in the voice box.
    @Published var sentEcho: SentEcho?
    /// A spoken command that acted at once ("undo that", "scratch that"), confirmed briefly in the voice box.
    @Published var voiceToast: VoiceToast?
    private var sendIsByVoice = false
    @Published var micLevel: Float = 0
    /// The voice in four pitch bands, 0…1, low to high; drives the mic's sound lines.
    @Published private(set) var micBands: [Double] = [0, 0, 0, 0]
    @Published private(set) var isMicPaused = false

    // MARK: Draft marks

    /// A sent request is being worked on.
    @Published private(set) var isWorking = false
    @Published private(set) var workingPlace: WorkingPlace?
    @Published private(set) var flash: ChangeFlash?
    @Published var answer: AnswerCard?
    /// The passage an answer is about, tinted while the answer is open.
    @Published var discussedRange: NSRange?
    /// Exact wording from "say exactly": underlined with a lock, never changed by an edit.
    @Published private(set) var locks: [String] = []
    /// Paragraphs the writer approved out loud, by their text.
    @Published private(set) var approved: Set<String> = []
    /// Bumped to put the cursor in the draft.
    @Published private(set) var focusRequest = 0
    /// Bumped to put the cursor in the voice box.
    @Published var focusVoice = 0
    /// The selection in the draft, kept current by the editor.
    var selection = NSRange(location: 0, length: 0)

    // MARK: Modes

    @Published var mode: WritingMode = .write
    /// Structure mode's plan for the draft.
    @Published var outline = Outline()
    /// Sections just added, tinted for a moment.
    @Published var freshSections: Set<String> = []
    /// Structure calls waiting or running.
    @Published var outlineBusy = 0
    var outlineTask: Task<Void, Never>?
    var outlineCheckTask: Task<Void, Never>?
    /// Outlines before each change, so Undo in Structure steps back through the plan.
    var outlineUndo: [(outline: Outline, movedDraft: Bool)] = []

    @Published var agents: [ReviewAgent] = WritingSession.savedAgents() {
        didSet { WritingSession.saveAgents(agents) }
    }
    @Published var comments: [ReviewComment] = []
    @Published var selectedComment: UUID?
    /// The comment being talked over with its agent, shown above the voice box.
    @Published var talkingTo: UUID?
    @Published var agentIsReplying = false
    @Published var runningAgents: Set<String> = []
    var reviewTasks: [Task<Void, Never>] = []

    /// Word-for-word dictation over a selection.
    @Published var dictation: Dictation?

    // MARK: Context and chrome

    @Published private(set) var contextItems: [ContextItem] = []
    /// Where the window or selection this draft reads came from, and what it's about.
    @Published var source: SourceNote?
    private var sourceSummaryTask: Task<Void, Never>?
    /// The spoken-command cards on an empty draft, until the first send.
    @Published var showCommandCards: Bool
    @Published private(set) var sourceAppName: String?
    @Published var engine: EditorEngine {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: "editorEngine")
            modelInfo = editorName
        }
    }

    @Published var debugLog: String = ""
    @Published var micInfo: String = "Mic not started"
    @Published var speechInfo: String = ""
    @Published var modelInfo: String = ""
    @Published var modelReady: Bool = false
    @Published var turns: [UtteranceTurn] = []

    var lastAssistantMessage = ""

    let document = DocumentModel()
    let modelStore = WhisperModelStore()
    let codex = CodexEditor()
    private let voice = VoiceCapture()
    private let stt: SpeechTranscriber
    private let interpreter: InterpreterClient
    private var previousApp: PreviousAppSnapshot?
    /// The text field Scriber was opened from, if any; Done pastes into it.
    private(set) var target: TextTarget?
    private var isOpen = false
    private var cancellables = Set<AnyCancellable>()

    /// What was said and done this session, so the editor can read "no, not like that".
    private var editorHistory: [EditorTurn] = []
    private(set) var lastChange: DocumentChange?

    private var speechActive = false
    private var sttInFlight = 0

    /// What a clip turned into, handed out in the order the clips were spoken.
    private enum ClipResult {
        case words(String)
        case nothing(voicedMs: Int)
        case failed(STTError)
    }
    private var clips = ClipSequencer<(id: Int, result: ClipResult)>()
    private var partials: [Int: String] = [:]
    private var partialInFlight = false
    /// Bumped when the mic restarts, so results from before don't land in the new numbering.
    private var micGeneration = 0
    /// Send waits for clips up to this one.
    private var sendThrough: Int?
    private var coolDownTask: Task<Void, Never>?
    private var labelGeneration = 0
    private var labelTask: Task<Void, Never>?
    /// Sent requests, oldest first; each waits for the one before it.
    private var work: [(id: UUID, task: Task<Void, Never>)] = []

    /// What was asked recently; the review pass checks the draft still honors the requests that stand.
    private var requests: [ReviewRequest] = []
    private var reviewTask: Task<Void, Never>?
    private var lastChangeWasReview = false
    /// Paragraphs the model already looked at, so only new or changed text gets polished.
    private var checkedParagraphs: Set<String> = []
    /// Each request gets at most one automatic second attempt.
    private var recheckedRequests: Set<UUID> = []
    /// Quiet time after an edit before the draft is checked as a whole.
    private let reviewDelay: UInt64 = 3_000_000_000

    struct Request {
        var text: String
        /// Labels for exactly this text, if they were ready when it was sent.
        var spans: [SpeechSpan]?
        var selection: (range: NSRange, text: String)?
        /// Written by ChatGPT whichever editor is chosen: outline sections and review changes.
        var forceCloud = false
        /// Where it will land, when that's known up front.
        var place: WorkingPlace?
        /// The place the writer named by position, for the editor.
        var pointed: NSRange?
    }

    init(interpreter: InterpreterClient = OllamaInterpreter()) {
        self.interpreter = interpreter
        self.engine = UserDefaults.standard.string(forKey: "editorEngine").flatMap(EditorEngine.init) ?? .chatgpt
        self.showCommandCards = !UserDefaults.standard.bool(forKey: "commandCardsDone")
        self.stt = WhisperCLITranscriber(modelStore: modelStore)
        self.speechInfo = stt.statusSummary
        self.contextItems = defaultContextItems()

        document.$text
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.documentText = text
                // Compare with the draft as it is now: this value may arrive after newer changes.
                let length = (self.document.text as NSString).length
                if self.discussedRange.map({ NSMaxRange($0) > length }) == true {
                    self.discussedRange = nil
                }
            }
            .store(in: &cancellables)

        modelStore.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .downloading(let name):
                    self.modelReady = false
                    self.status = .downloadingModel(name)
                    self.speechInfo = "Downloading Whisper \(name)"
                case .ready:
                    self.modelReady = true
                    self.speechInfo = "Whisper \(self.modelStore.modelDisplayName)"
                    if self.isOpen { self.status = self.isMicPaused ? .idle : .listening }
                    if self.isOpen { Task { await self.stt.warmUp() } }
                case .failed(let message):
                    self.modelReady = false
                    self.status = .error(message)
                    self.speechInfo = message
                case .idle:
                    break
                }
            }
            .store(in: &cancellables)

        voice.onClip = { [weak self] id, audio, voicedMs, loudness in
            Task { @MainActor in self?.clipFinished(id, audio: audio, voicedMs: voicedMs, loudness: loudness) }
        }
        voice.onPartial = { [weak self] id, audio in
            Task { @MainActor in self?.partialReady(id, audio: audio) }
        }
        voice.onLevel = { [weak self] level, bands in
            Task { @MainActor in
                self?.micLevel = level
                self?.micBands = bands
            }
        }
        voice.onInfo = { [weak self] info in
            Task { @MainActor in self?.appendDebug(info) }
        }
        voice.onSpeechStart = { [weak self] _ in
            Task { @MainActor in self?.speechStarted() }
        }
        voice.onSpeechEnd = { [weak self] _ in
            Task { @MainActor in self?.speechEnded() }
        }
    }

    func prepareBackends() {
        Task {
            await modelStore.ensureReady()
            await interpreter.warm()
            modelInfo = editorName
            appendDebug("Backends warm · Whisper \(modelStore.modelDisplayName) · LLM \(interpreter.modelName) · editor \(editorName)")
            speechInfo = "Whisper \(modelStore.modelDisplayName)"
        }
    }

    /// ChatGPT edits only when the Codex CLI is there; otherwise the local model does.
    var usesCloud: Bool { engine == .chatgpt && codex.isAvailable }

    var editorName: String {
        if engine == .chatgpt {
            return codex.isAvailable ? codex.displayName : "Local \(interpreter.modelName) (Codex CLI not found)"
        }
        return "Local \(interpreter.modelName)"
    }

    var canUndo: Bool { mode == .structure ? !outlineUndo.isEmpty || document.canUndo : document.canUndo }
    var canRedo: Bool { document.canRedo }

    var wordCount: Int {
        document.text.split(whereSeparator: \.isWhitespace).count
    }

    /// "Email to Tomas" once there's a greeting, "New draft" before there's anything.
    var title: String {
        let paragraphs = DocumentParagraphs.split(documentText)
        guard let first = paragraphs.first?.text else { return "New draft" }
        let ns = first as NSString
        if let regex = try? NSRegularExpression(pattern: #"^(?i:hi|hello|hey|dear)\s+([\p{Lu}][\p{L}'’-]+)"#),
           let match = regex.firstMatch(in: first, range: NSRange(location: 0, length: ns.length)) {
            return "Email to \(ns.substring(with: match.range(at: 1)))"
        }
        return "Draft"
    }

    // MARK: - Opening and closing

    /// Menu bar setting. Off: the window opens with the mic off until you click it, so coming back to a draft
    /// doesn't pick up the room.
    static let listenOnOpenKey = "listenOnOpen"
    /// Menu bar setting: every ChatGPT edit uses the thorough model, never the fast one.
    static var alwaysThorough: Bool { UserDefaults.standard.bool(forKey: "codexAlwaysThorough") }
    static var listensOnOpen: Bool { UserDefaults.standard.bool(forKey: listenOnOpenKey) }

    func open(remembering app: PreviousAppSnapshot?, target: TextTarget? = nil) {
        previousApp = app
        sourceAppName = app?.name
        self.target = target
        isOpen = true
        isMicPaused = !Self.listensOnOpen
        if document.text.isEmpty {
            contextItems = defaultContextItems()
            // Text selected in the field is where the draft starts; Done replaces it.
            let selected = target?.selectedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !selected.isEmpty {
                document.userEdited(selected)
                appendDebug("Started from the selection in \(target?.appName ?? "the field") (\(selected.count) chars)")
            }
        }
        focusRequest += 1
        coolDownTask?.cancel()
        Task { await stt.warmUp() }
        Task { [interpreter] in await interpreter.warm() }
        if isMicPaused {
            status = modelReady ? .idle : .downloadingModel(modelStore.modelDisplayName)
            appendDebug("Opened with the mic off")
        } else {
            status = modelReady ? .listening : .downloadingModel(modelStore.modelDisplayName)
            startMic()
        }
    }

    func close() {
        isOpen = false
        cancelDictation()
        voice.stop()
        cancelWork()
        cancelReview()
        speechActive = false
        sttInFlight = 0
        updateHearing()
        missedSpeech = false
        clearLiveWords()
        status = .idle
        micLevel = 0
        micBands = [0, 0, 0, 0]
        // Keep Whisper loaded for a while in case the panel comes right back.
        coolDownTask?.cancel()
        coolDownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard !Task.isCancelled, let self, !self.isOpen else { return }
            self.stt.coolDown()
        }
    }

    func stop() {
        close()
        coolDownTask?.cancel()
        stt.coolDown()
    }

    /// Copies the draft, closes, and starts a fresh draft for next time (⌘Z after reopening brings this one back).
    /// Returns the app to go back to and the field to paste into.
    func finish() -> (app: PreviousAppSnapshot?, target: TextTarget?, text: String) {
        Self.copyToClipboard(document.text)
        // The Accessibility fallback can only put in plain text.
        let result = (previousApp, target, ClipboardText.plain(document.text))
        close()
        startNewDraft()
        return result
    }

    private func startNewDraft() {
        document.userEdited("", at: .distantPast)
        resetModes()
        clearTransientMarks()
        clearUnsent()
        answer = nil
        locks = []
        approved = []
        target = nil
        contextItems = defaultContextItems()
    }

    /// Opened again from another text field while already open: Done now goes there.
    func retarget(_ field: TextTarget, from app: PreviousAppSnapshot?) {
        target = field
        previousApp = app
        sourceAppName = app?.name
    }

    /// The window the writer came from is being read; the banner says so until it's done.
    func beginReadingScreen(app: String) {
        clearSource()
        source = SourceNote(kind: .window, app: app, state: .reading)
    }

    /// What the window the writer came from says, or why it couldn't be read.
    func setScreen(_ result: ScreenReader.Result) {
        guard var note = source, note.kind == .window else { return }
        switch result {
        case .read(let reading):
            contextItems.insert(ContextItem(screen: reading), at: 0)
            note.title = reading.title
            note.state = .ready
            source = note
            describeSource(app: reading.app, title: reading.title, text: reading.text)
        case .failed(let reason):
            note.state = .failed(reason)
            source = note
        case .needsPermission:
            note.state = .needsPermission
            source = note
        }
    }

    /// Text selected in another app: what the draft responds to, instead of the whole window.
    func setSelection(_ selected: SelectedText) {
        clearSource()
        contextItems.insert(ContextItem(selection: selected), at: 0)
        source = SourceNote(kind: .selection, app: selected.app, title: selected.window, state: .ready, excerpt: selected.text)
        appendDebug("Selection from \(selected.app): \(selected.text.count) chars")
    }

    /// The writer closed the banner: the draft no longer reads the window or selection.
    func clearSource() {
        sourceSummaryTask?.cancel()
        contextItems.removeAll(where: \.isSource)
        source = nil
    }

    /// A line on what the window is about ("Email from Tomas · Re: yesterday"), so it's clear what the editor sees.
    private func describeSource(app: String, title: String, text: String) {
        sourceSummaryTask?.cancel()
        guard usesCloud else { return }
        let codex = self.codex
        sourceSummaryTask = Task { [weak self] in
            let started = Date()
            do {
                let summary = try await codex.describeSource(app: app, title: title, text: text)
                guard let self, !Task.isCancelled, var note = self.source, note.kind == .window, note.app == app else { return }
                note.headline = summary.headline
                note.summary = summary.summary
                self.source = note
                self.appendDebug("Source \(Int(Date().timeIntervalSince(started) * 1000))ms: \(summary.headline) · \(summary.summary)")
            } catch {
                self?.appendDebug("Source summary failed: \(error.localizedDescription)")
            }
        }
    }

    /// Plain text plus simple HTML paragraphs, so email editors keep the paragraphs and their own font.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ClipboardText.plain(text), forType: .string)
        pasteboard.setString(ClipboardText.html(text), forType: .html)
    }

    func toggleMicPause() {
        isMicPaused.toggle()
        if isMicPaused {
            // Finish the sentence in progress instead of dropping it.
            voice.finalizeNow { _ in }
            voice.stop()
            speechActive = false
            updateHearing()
            status = .idle
            micLevel = 0
            micBands = [0, 0, 0, 0]
            appendDebug("Mic paused")
        } else if isOpen {
            startMic()
            status = modelReady ? .listening : .downloadingModel(modelStore.modelDisplayName)
        }
    }

    func startMic() {
        micGeneration += 1
        clips.reset()
        clearLiveWords()
        do {
            try voice.start()
            micInfo = voice.inputDeviceName
            appendDebug("Mic started · \(voice.inputDeviceName)")
        } catch {
            status = .error(error.localizedDescription)
            micInfo = error.localizedDescription
            appendDebug("Mic error: \(error)")
        }
    }

    // MARK: - Hearing speech

    private func speechStarted() {
        guard isOpen, !isMicPaused else { return }
        speechActive = true
        updateHearing()
        cancelReview()
    }

    private func speechEnded() {
        speechActive = false
        updateHearing()
    }

    private func updateHearing() {
        if speechActive != isCapturing { isCapturing = speechActive }
        if (sttInFlight > 0) != isTranscribing { isTranscribing = sttInFlight > 0 }
        if speechActive, missedSpeech { missedSpeech = false }
    }

    private var missedTask: Task<Void, Never>?

    /// A clip ended. Its words are worked out now but only used once every earlier clip is in.
    private func clipFinished(_ id: Int, audio: AVAudioPCMBuffer?, voicedMs: Int, loudness: NoiseFilter.Loudness?) {
        let generation = micGeneration
        guard let audio, isOpen else {
            deliver(id, .nothing(voicedMs: voicedMs), generation: generation)
            return
        }
        stt.vocabulary = speakerVocabulary()
        sttInFlight += 1
        updateHearing()
        let seconds = Double(audio.frameLength) / audio.format.sampleRate
        appendDebug(String(format: "Whisper · clip %d · %.2fs audio · %dms voice", id, seconds, voicedMs))
        Task { [weak self] in
            guard let self else { return }
            let t0 = Date()
            let result: ClipResult
            do {
                let text = try await self.stt.transcribe(audio)
                self.appendDebug("Whisper \(Int(Date().timeIntervalSince(t0) * 1000))ms · clip \(id) → \"\(text)\"")
                if let loudness, NoiseFilter.isPhantom(text, loudness) {
                    // "Thank you." out of a quiet clip is Whisper describing background noise.
                    self.appendDebug("Clip \(id): dropped \"\(text)\" (heard in noise)")
                    result = .nothing(voicedMs: 0)
                } else {
                    result = .words(text)
                }
            } catch let error as STTError {
                self.appendDebug("STT error · clip \(id): \(error.localizedDescription)")
                if case .empty = error { result = .nothing(voicedMs: voicedMs) } else { result = .failed(error) }
            } catch {
                result = .failed(.unavailable(error.localizedDescription))
            }
            self.sttInFlight -= 1
            self.updateHearing()
            self.deliver(id, result, generation: generation)
        }
    }

    /// Uses finished clips in spoken order, then sends if Send was waiting for them.
    private func deliver(_ id: Int, _ result: ClipResult, generation: Int) {
        guard generation == micGeneration else { return }
        for clip in clips.finish(id, (id, result)) {
            partials[clip.id] = nil
            switch clip.result {
            case .words(let text):
                hear(text)
            case .nothing(let voicedMs):
                if voicedMs >= 700 { flagMissedSpeech() }
            case .failed(let error):
                if case .unavailable(let message) = error { status = .error(message) }
            }
        }
        updateLiveWords()
        if let through = sendThrough, clips.hasHandedOut(through: through) {
            sendThrough = nil
            sendPending = false
            sendNow()
        }
    }

    /// Rough words for the clip being spoken, so you can see you're heard. Skipped while a clip is being finished.
    private func partialReady(_ id: Int, audio: AVAudioPCMBuffer) {
        guard isOpen, !partialInFlight, sttInFlight == 0, !clips.hasHandedOut(through: id) else { return }
        partialInFlight = true
        let generation = micGeneration
        Task { [weak self] in
            guard let self else { return }
            let text = await self.stt.transcribePartial(audio)
            self.partialInFlight = false
            guard generation == self.micGeneration, !self.clips.hasHandedOut(through: id), !text.isEmpty else { return }
            self.partials[id] = text
            self.updateLiveWords()
        }
    }

    private func updateLiveWords() {
        let words = partials.keys.sorted().compactMap { partials[$0] }.joined(separator: " ")
        if words != liveWords { liveWords = words }
    }

    private func clearLiveWords() {
        partials.removeAll()
        liveWords = ""
        sendThrough = nil
        sendPending = false
    }

    /// Says "didn't catch that" in the voice box for a few seconds.
    private func flagMissedSpeech() {
        missedSpeech = true
        missedTask?.cancel()
        missedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.missedSpeech = false
        }
    }

    /// Speech only collects; it goes to the editor on Send or "okay, send". A few phrases act at once.
    private func hear(_ raw: String) {
        let fragment = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty else { return }
        if dictation != nil {
            hearWordForWord(fragment)
            return
        }
        let action = VoicePhrases.classify(fragment)
        appendDebug("Heard \(action)")
        switch action {
        case .undo:
            undo()
            toast("Undone")
        case .redo:
            redo()
            toast("Redone")
        case .cancel:
            cancelWork()
            toast("Stopped")
        case .scratch:
            clearUnsent()
            toast("Scratched")
        case .append(let text): appendUnsent(text)
        case .send(let text):
            if !text.isEmpty { appendUnsent(text) }
            sendIsByVoice = true
            sendNow()
        }
    }

    // MARK: - Unsent text

    private func appendUnsent(_ text: String) {
        unsentText = unsentText.isEmpty ? text : unsentText + " " + text
        startLabeling()
    }

    /// The writer edited the unsent text by hand.
    func setUnsent(_ text: String) {
        guard text != unsentText else { return }
        if !text.hasPrefix(unsentText) { unsentSpans = [] }
        unsentText = text
        startLabeling(after: 600_000_000)
    }

    private func toast(_ text: String) {
        voiceToast = VoiceToast(text: text)
    }

    func clearUnsent() {
        labelTask?.cancel()
        labelTask = nil
        labelGeneration += 1
        unsentText = ""
        unsentSpans = []
    }

    private func startLabeling(after delay: UInt64 = 0) {
        labelTask?.cancel()
        labelGeneration += 1
        let generation = labelGeneration
        let text = unsentText
        let doc = document.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            labelTask = nil
            return
        }
        // The rules colour the command, the place and exact words at once; the labeler fills in the rest.
        let ruleSpans = SpokenMechanics.spans(for: text)
        if !ruleSpans.isEmpty { unsentSpans = ruleSpans }
        labelTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled else { return }
            let spans = await self.labels(for: text, document: doc)
            guard !Task.isCancelled, generation == self.labelGeneration else { return }
            self.unsentSpans = SpokenMechanics.merged(rules: ruleSpans, labels: spans)
            self.labelTask = nil
        }
    }

    /// How each part of what was said reads. Spoken commands are parsed in code; the rest goes to the local labeler.
    private func labels(for text: String, document doc: String) async -> [SpeechSpan] {
        if !usesCloud, let commands = CommandParser.parseAll(text), !Completeness.looksUnfinished(text) {
            return Self.spans(for: commands, in: text)
        }
        let clauses = ClauseChunker.clauses(text)
        let t0 = Date()
        do {
            let labeling = try await interpreter.label(clauses: clauses, document: doc)
            let spans = SpanBuilder.spans(utterance: text, clauses: clauses, labels: labeling.labels)
            appendDebug("Labels \(Int(Date().timeIntervalSince(t0) * 1000))ms · " + SpanPlanner.describe(spans))
            return spans
        } catch {
            appendDebug("Label error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Sending

    /// Send button or Return: ends the sentence being spoken and waits until everything said before the press
    /// is transcribed, so the last words aren't left behind for the next message.
    func send() {
        let hasSpeech = isCapturing || isTranscribing || !liveWords.isEmpty
        guard hasSpeech || !unsentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dictation != nil,
              !sendPending else { return }
        guard hasSpeech else {
            sendNow()
            return
        }
        sendPending = true
        let generation = micGeneration
        voice.finalizeNow { [weak self] last in
            Task { @MainActor in
                guard let self, generation == self.micGeneration, self.sendPending else { return }
                if self.clips.hasHandedOut(through: last) {
                    self.sendPending = false
                    self.sendNow()
                } else {
                    self.sendThrough = last
                }
            }
        }
        // Don't wait forever on a transcription that's stuck.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, generation == self.micGeneration, self.sendPending else { return }
            self.appendDebug("Send waited 12 s for transcription — sending what's there")
            self.sendThrough = nil
            self.sendPending = false
            self.sendNow()
        }
    }

    /// Sends the unsent text to the editor, with the selection as its target if there is one.
    private func sendNow() {
        if dictation != nil {
            commitDictation()
            return
        }
        let text = unsentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let byVoice = sendIsByVoice
        sendIsByVoice = false
        guard !text.isEmpty else { return }
        let spans: [SpeechSpan]? = labelTask == nil ? unsentSpans : nil
        sentEcho = SentEcho(text: text, byVoice: byVoice)
        clearUnsent()
        switch mode {
        case .structure:
            runOutline(.edit(speech: text))
        case .review where talkingTo != nil || selectedComment != nil:
            replyToAgent(text)
        default:
            let selection = mode == .write ? currentSelection() : nil
            if mode == .write, applyMechanical(text) { return }
            var request = Request(text: text, spans: spans, selection: selection)
            if selection == nil, let pointed = SpokenMechanics.pointed(in: text, draft: document.text, selection: nil) {
                request.pointed = pointed.range
                request.place = .range(pointed.range)
            }
            enqueue(request)
        }
    }

    /// Edits the rules can do alone (move, delete, merge, split, exact words, bold, list): applied at once,
    /// as one version, with no model. False when it isn't one of those.
    private func applyMechanical(_ said: String) -> Bool {
        guard let edit = SpokenMechanics.edit(in: said) else { return false }
        let before = document.text
        guard let after = SpokenMechanics.apply(edit, to: before, selection: currentSelection()?.range), after != before else {
            appendDebug("Rules: “\(said)” didn't fit the draft, asking the editor")
            return false
        }
        if showCommandCards {
            showCommandCards = false
            UserDefaults.standard.set(true, forKey: "commandCardsDone")
        }
        answer = nil
        discussedRange = nil
        let op = DocumentOp(op: .replace, text: after, target: "whole_document")
        guard document.apply(ops: [op], expectedRevision: document.revision) == .applied else { return false }
        recordChange(before: before, note: edit.summary)
        // Exact words stay as said: they're locked like "say exactly" through the editor, in the form the draft
        // now has them (a new sentence starts with a capital).
        switch edit {
        case .replaceExactly(_, let words), .insertExactly(let words, _, _):
            let form = after.contains(words) ? words : words.prefix(1).uppercased() + words.dropFirst()
            if words.split(separator: " ").count >= 2, after.contains(form), !locks.contains(form) { locks.append(form) }
        default: break
        }
        noteInHistory(said, edit.summary)
        appendDebug("Rules: \(edit.summary) · “\(said)”")
        logTurn(utterance: said, spans: unsentSpans, intent: .edit, ops: [op], note: "[rules] \(edit.summary)",
                documentBefore: before, documentAfter: after, model: "rules")
        return true
    }

    /// What's being said names a place in the draft: it lights up before it's sent.
    private func updatePointed() {
        guard mode == .write, dictation == nil else {
            if pointedRange != nil { pointedRange = nil }
            return
        }
        let said = [unsentText, liveWords].filter { !$0.isEmpty }.joined(separator: " ")
        let range = said.isEmpty ? nil : SpokenMechanics.pointed(in: said, draft: document.text, selection: nil)?.range
        if range != pointedRange { pointedRange = range }
    }

    /// Runs the editor's last suggestion as an edit.
    func applySuggestion() {
        guard answer?.canApply == true else { return }
        answer = nil
        discussedRange = nil
        enqueue(Request(text: "Do what you just suggested.", spans: [], selection: nil))
    }

    func dismissAnswer() {
        answer = nil
        discussedRange = nil
    }

    func currentSelection() -> (range: NSRange, text: String)? {
        let ns = document.text as NSString
        guard selection.length > 0, NSMaxRange(selection) <= ns.length else { return nil }
        let text = ns.substring(with: selection)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (selection, text)
    }

    func enqueue(_ request: Request) {
        if showCommandCards {
            showCommandCards = false
            UserDefaults.standard.set(true, forKey: "commandCardsDone")
        }
        answer = nil
        discussedRange = nil
        cancelReview()
        appendDebug("Send → \"\(request.text)\"" + (request.selection.map { " · selection \"\($0.text.prefix(60))\"" } ?? ""))

        let previous = work.last?.task
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            self.isWorking = true
            await self.perform(request)
            self.workingPlace = nil
            self.work.removeAll { $0.id == id }
            self.isWorking = !self.work.isEmpty
            if self.work.isEmpty, self.lastChange != nil, !self.usesCloud { self.scheduleReview() }
        }
        work.append((id, task))
        isWorking = true
    }

    /// "Stop" / "wait": drop what's being written and anything sent after it.
    func cancelWork() {
        guard !work.isEmpty else { return }
        work.forEach { $0.task.cancel() }
        work.removeAll()
        isWorking = false
        workingPlace = nil
        appendDebug("Cancelled")
    }

    private func perform(_ request: Request) async {
        if UtterancePolicy.isClearCommand(request.text) {
            clearDocument(heard: request.text)
            return
        }
        if usesCloud || (request.forceCloud && codex.isAvailable) {
            await runCloud(request)
        } else {
            await runLocal(request)
        }
    }

    // MARK: - History

    func undo() {
        cancelReview()
        if mode == .structure, !outlineUndo.isEmpty {
            undoOutline()
            return
        }
        guard document.undo() else { return }
        forgetUndoneRequest()
        clearTransientMarks()
        noteInHistory("undo", "The writer undid the last change")
    }

    func redo() {
        cancelReview()
        guard document.redo() else { return }
        clearTransientMarks()
        noteInHistory("redo", "The writer redid the change they had undone")
    }

    private func clearTransientMarks() {
        lastChange = nil
        flash = nil
        discussedRange = nil
    }

    // MARK: - Typing in the draft

    /// The draft as the writer typed it. A burst of typing is one version in history.
    func userEdited(_ text: String) {
        guard text != document.text else { return }
        let before = document.text
        cancelReview()
        document.userEdited(text)
        // Editing locked words by hand releases the lock.
        let released = LockedWording.broken(locks, before: before, after: text)
        if !released.isEmpty { locks.removeAll { released.contains($0) } }
        discussedRange = nil
    }

    // MARK: - Context

    /// Every draft starts with who's writing and how, once those files say something.
    private func defaultContextItems() -> [ContextItem] {
        let store = ContextStore.shared
        return [ContextStore.profileName, ContextStore.styleName]
            .map { store.url($0) }
            .filter { store.hasContent($0) }
            .map { ContextItem(url: $0, automatic: true) }
    }

    func addContext(_ url: URL) {
        guard !contextItems.contains(where: { $0.url == url }) else { return }
        contextItems.append(ContextItem(url: url, automatic: false))
    }

    func isUsing(_ url: URL) -> Bool {
        contextItems.contains { $0.url?.standardizedFileURL == url.standardizedFileURL }
    }

    /// The picker: a file goes into this draft's context, or comes out of it.
    func toggleContext(_ url: URL) {
        if let item = contextItems.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
            removeContext(item)
        } else {
            addContext(url)
        }
    }

    /// Removes a file from this draft's context only.
    func removeContext(_ item: ContextItem) {
        contextItems.removeAll { $0 == item }
    }

    /// The files this draft uses, plus the window or selection it came from.
    func contextBundle(for speech: String) -> ContextBundle {
        let store = ContextStore.shared
        let root = store.rootURL.standardizedFileURL
        var bundle = ContextBundle(profile: "", style: "", project: "", projectName: "")
        var extra: [String] = []
        for item in contextItems {
            switch item.source {
            case .file(let url):
                let text = store.content(url)
                guard !text.isEmpty else { continue }
                let inRoot = url.standardizedFileURL.deletingLastPathComponent() == root
                if inRoot, url.lastPathComponent == ContextStore.profileName {
                    bundle.profile = text
                } else if inRoot, url.lastPathComponent == ContextStore.styleName {
                    bundle.style = text
                } else {
                    extra.append("## \(store.relativeName(url))\n\(text)")
                }
            case .screen(let reading):
                bundle.screen = "The window of \(reading.app)" + (reading.title.isEmpty ? "" : " — “\(reading.title)”") + ", read by OCR:\n" + reading.text
            case .selection(let selected):
                bundle.screen = "Text the writer selected in \(selected.app)" + (selected.window.isEmpty ? "" : " — “\(selected.window)”") + ":\n" + selected.text
            }
        }
        bundle.extra = extra.joined(separator: "\n\n")
        if !usesCloud {
            let more = [bundle.extra, bundle.screen].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !more.isEmpty { bundle.project += (bundle.project.isEmpty ? "" : "\n\n") + more }
        }
        return bundle
    }

    // MARK: - ChatGPT editing

    private func runCloud(_ request: Request) async {
        let sent = document.text
        var marks = draftMarks(in: sent, selection: request.selection)
        if request.selection == nil, let pointed = request.pointed, NSMaxRange(pointed) <= (sent as NSString).length {
            let paragraphs = DocumentParagraphs.split(sent)
            let numbers = paragraphs.indices.filter { NSIntersectionRange(paragraphs[$0].range, pointed).length > 0 }.map { "p\($0 + 1)" }
            marks.pointed = "“\((sent as NSString).substring(with: pointed))” (in \(numbers.joined(separator: ", ")))"
        }
        let history = Array(editorHistory.filter { Date().timeIntervalSince($0.at) < 20 * 60 }.suffix(6))
        let context = contextBundle(for: request.text)
        let codex = self.codex
        let started = Date()
        // Everyday edits go to the fast model; reworking the whole draft and long briefs to the thorough one.
        let fast = !Self.alwaysThorough && !request.forceCloud && !EditRouting.needsThorough(request.text)
        let modelName = codex.displayName(fast: fast)
        let task = Task.detached {
            try await codex.edit(document: sent, speech: request.text, history: history, context: context, marks: marks, fast: fast)
        }

        workingPlace = request.selection.map { .range($0.range) } ?? request.place
            ?? request.spans.flatMap { Self.guessPlace(spans: $0, document: sent) }
        var spans = request.spans ?? []
        if request.spans == nil {
            spans = await labels(for: request.text, document: sent)
            if workingPlace == nil, !Task.isCancelled { workingPlace = Self.guessPlace(spans: spans, document: sent) }
        }

        do {
            let (edit, raw) = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if Task.isCancelled { return }
            appendDebug("ChatGPT \(Int(Date().timeIntervalSince(started) * 1000))ms [\(fast ? "fast" : "thorough")]: \(raw)")
            applyCloud(edit, sent: sent, request: request, spans: spans, model: modelName)
        } catch {
            guard !Task.isCancelled else { return }
            let message = error.localizedDescription
            appendDebug("ChatGPT error: \(message)")
            answer = AnswerCard(kind: .failed, message: message)
            logTurn(utterance: request.text, spans: spans, intent: nil, ops: [], note: message,
                    documentBefore: sent, documentAfter: sent, model: modelName)
            pushTurn(UtteranceTurn(transcript: request.text, explanation: message, outcome: .failed, spans: spans))
        }
    }

    private func applyCloud(_ edit: CloudEdit, sent: String, request: Request, spans: [SpeechSpan], model: String) {
        let before = document.text
        let skipped = edit.couldNotDo.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let reply = edit.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        var applied = false
        var problem: String?

        do {
            let after = try ParagraphEdits.apply(edit.ops, sent: sent, current: before)
            if after != before {
                let op = DocumentOp(op: .replace, text: after, target: "whole_document")
                if document.apply(ops: [op], expectedRevision: document.revision) == .applied {
                    applied = landed(before: before, note: ParagraphEdits.describe(edit.ops), speech: request.text, spans: spans)
                }
            }
        } catch {
            problem = error.localizedDescription
        }
        approve(ids: edit.approved, sent: sent)
        if !reply.isEmpty { lastAssistantMessage = reply }

        if answer == nil {
            if applied {
                let note = ([reply] + skipped.map { "Couldn't: \($0)" }).filter { !$0.isEmpty }.joined(separator: "\n")
                if !note.isEmpty { answer = AnswerCard(kind: .note, message: note) }
            } else if !reply.isEmpty {
                answer = AnswerCard(kind: .answer, message: reply)
                discussedRange = discussed(request: request, spans: spans)
            } else if let reason = skipped.first ?? problem {
                answer = AnswerCard(kind: .notDone, message: reason)
            }
        }

        let outcome = applied
            ? Self.historyLine(edit.ops, before: before)
            : (skipped.first.map { "Nothing changed — couldn't: \($0)" } ?? (reply.isEmpty ? "Nothing changed" : "Replied: \(reply.prefix(200))"))
        noteInHistory(request.text, outcome)
        let opsJSON = (try? JSONEncoder().encode(edit.ops)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        logTurn(utterance: request.text, spans: spans, intent: applied ? .edit : .discuss,
                ops: applied ? [DocumentOp(op: .replace, text: document.text, target: "whole_document")] : [],
                note: "[ChatGPT] \(applied ? ParagraphEdits.describe(edit.ops) : "no change") · ops=\(opsJSON)"
                    + (reply.isEmpty ? "" : " · reply=\(reply)") + (edit.approved.isEmpty ? "" : " · approved=\(edit.approved)"),
                documentBefore: before, documentAfter: document.text, model: model)
        pushTurn(UtteranceTurn(transcript: request.text, intent: applied ? .edit : .discuss, explanation: outcome,
                               outcome: applied ? .applied : .discussed, spans: spans))
    }

    /// What the writer marked, numbered like the draft that's sent.
    private func draftMarks(in document: String, selection: (range: NSRange, text: String)?) -> DraftMarks {
        let paragraphs = DocumentParagraphs.split(document)
        var marks = DraftMarks()
        marks.locks = locks.filter { document.contains($0) }
        if !outline.isEmpty { marks.outline = outline.described() }
        marks.approved = paragraphs.indices.filter { approved.contains(paragraphs[$0].text) }.map { $0 + 1 }
        if let selection {
            let numbers = paragraphs.indices.filter { NSIntersectionRange(paragraphs[$0].range, selection.range).length > 0 }.map { $0 + 1 }
            marks.selection = (selection.text, numbers)
        }
        return marks
    }

    /// The editor's approvals ("p1") point at the draft as it was sent.
    private func approve(ids: [String], sent: String) {
        let sentParagraphs = DocumentParagraphs.split(sent).map(\.text)
        let current = Set(DocumentParagraphs.split(document.text).map(\.text))
        for id in ids {
            guard let n = ParagraphEdits.number(id), sentParagraphs.indices.contains(n - 1) else { continue }
            let text = sentParagraphs[n - 1]
            if current.contains(text) { approved.insert(text) }
        }
    }

    /// What the editor did, in words it can refer back to next turn.
    static func historyLine(_ ops: [ParagraphOp], before: String) -> String {
        let paragraphs = DocumentParagraphs.split(before).map(\.text)
        func old(_ id: String) -> String {
            guard let n = ParagraphEdits.number(id), paragraphs.indices.contains(n - 1) else { return "" }
            return " (was: \"\(paragraphs[n - 1].prefix(160))\")"
        }
        return ops.map { op in
            switch op.op {
            case .replace: return "rewrote \(op.id)\(old(op.id)) as \"\(op.text.prefix(240))\""
            case .delete: return "deleted \(op.id)\(old(op.id))"
            case .insertAfter: return "added after \(op.id): \"\(op.text.prefix(240))\""
            case .insertBefore: return "added before \(op.id): \"\(op.text.prefix(240))\""
            }
        }.joined(separator: "; ")
    }

    /// The labels' best guess at where the edit lands: a located target, or a new paragraph above the sign-off.
    static func guessPlace(spans: [SpeechSpan], document: String) -> WorkingPlace? {
        let visible = TextLocator.visibleParagraphs(in: document)
        guard !visible.isEmpty else { return .end }
        for span in spans where span.role == .target {
            if let numbers = CommandParser.paragraphNumbers(span.quote), let n = numbers.first {
                let index = n == -1 ? visible.count - 1 : n - 1
                if visible.indices.contains(index) { return .paragraph(index) }
            }
            if let match = TextLocator.find(span.quote, in: document),
               let index = visible.firstIndex(where: { $0.contains(match.range.lowerBound) || $0.lowerBound >= match.range.lowerBound }) {
                return .paragraph(index)
            }
        }
        guard spans.contains(where: { $0.role == .payload || $0.role == .brief }) else { return nil }
        if let closing = TextLocator.blocks(in: document).last, TextLocator.blocks(in: document).count > 1,
           CommandPlanner.isClosing(String(document[closing])),
           let index = visible.firstIndex(where: { $0.lowerBound >= closing.lowerBound }) {
            return .insert(before: index)
        }
        return .end
    }

    /// The passage a question was about: the selection, or the first target found in the draft.
    private func discussed(request: Request, spans: [SpeechSpan]) -> NSRange? {
        if let selection = request.selection { return selection.range }
        let doc = document.text
        for span in spans where span.role == .target {
            if let match = TextLocator.find(span.quote, in: doc) { return NSRange(match.range, in: doc) }
        }
        return nil
    }

    // MARK: - After an edit lands

    /// Every AI change goes through here: locked wording is checked, the change glows, new exact wording is locked.
    /// Returns false if the change was taken back.
    @discardableResult
    private func landed(before: String, note: String, speech: String?, spans: [SpeechSpan], exact: [String] = []) -> Bool {
        let after = document.text
        let broken = LockedWording.broken(locks, before: before, after: after)
        if !broken.isEmpty {
            document.discardLastChange()
            answer = AnswerCard(kind: .kept,
                                message: "That edit would have changed “\(broken[0].prefix(90))”. Edit it by hand if you want it different.")
            appendDebug("Refused an edit that broke locked wording: \(broken)")
            return false
        }
        recordChange(before: before, note: note)
        if let speech { lockExactWording(speech: speech, spans: spans, extra: exact, after: after) }
        return true
    }

    func recordChange(before: String, note: String) {
        let after = document.text
        lastChange = DocumentChange(after: after, note: note, changes: ParagraphDiff.changes(before: before, after: after))
        flash = ChangeFlash(after: after, ranges: ParagraphDiff.addedRanges(before: before, after: after), start: Date())
        lastChangeWasReview = false
        draftChanged()
    }

    /// "Say exactly …" wording that just landed gets locked.
    private func lockExactWording(speech: String, spans: [SpeechSpan], extra: [String], after: String) {
        var candidates = extra
        if VoicePhrases.asksForExactWording(speech) {
            candidates += spans.filter { $0.role == .payload }.map(\.quote)
            candidates += VoicePhrases.exactWording(in: speech)
        }
        let ns = after as NSString
        let added = flash?.ranges ?? []
        for candidate in candidates {
            let words = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard words.split(separator: " ").count >= 2 else { continue }
            var range = ns.range(of: words, options: .caseInsensitive)
            if range.location == NSNotFound, let match = TextLocator.find(words, in: after), match.score >= 0.8 {
                range = NSRange(match.range, in: after)
            }
            guard range.location != NSNotFound,
                  added.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            // Take the sentence's own punctuation with it, so the lock sits after "plan." not before the period.
            while NSMaxRange(range) < ns.length,
                  let scalar = UnicodeScalar(ns.character(at: NSMaxRange(range))),
                  CharacterSet(charactersIn: ".!?,;:”\"").contains(scalar) {
                range.length += 1
            }
            let text = ns.substring(with: range)
            if !locks.contains(text) {
                locks.append(text)
                appendDebug("Locked \"\(text)\"")
            }
        }
    }

    func noteInHistory(_ said: String, _ outcome: String) {
        editorHistory.append(EditorTurn(said: said, outcome: outcome, at: Date()))
        if editorHistory.count > 12 { editorHistory.removeFirst(editorHistory.count - 12) }
    }

    // MARK: - Local editing

    private func runLocal(_ request: Request) async {
        let doc = document.text
        var spans = request.spans ?? []
        if request.spans == nil { spans = await labels(for: request.text, document: doc) }
        if Task.isCancelled { return }

        if let commands = CommandParser.parseAll(request.text), !Completeness.looksUnfinished(request.text) {
            let resolved = request.selection.map { SelectionTarget.apply(commands, selection: $0.text) } ?? commands
            workingPlace = request.selection.map { .range($0.range) } ?? Self.guessPlace(spans: spans, document: doc)
            await run(resolved, utterance: request.text, spans: spans)
        } else {
            if let selection = request.selection {
                spans.insert(SpeechSpan(role: .target, quote: selection.text), at: 0)
            }
            workingPlace = request.selection.map { .range($0.range) } ?? Self.guessPlace(spans: spans, document: doc)
            await act(on: request.text, spans: spans, selection: request.selection?.range)
        }
        approveSpoken(request.text)
    }

    /// "Good, the opening works" with the local engine.
    private func approveSpoken(_ speech: String) {
        let doc = document.text
        let paragraphs = DocumentParagraphs.split(doc)
        for reference in ApprovalParser.references(in: speech) {
            if let index = ApprovalParser.paragraph(for: reference, in: doc), paragraphs.indices.contains(index) {
                approved.insert(paragraphs[index].text)
                appendDebug("Approved ¶\(index + 1) (“\(reference)”)")
            }
        }
    }

    /// Runs commands in order against the draft; locating happens in code, the model only writes rewrites.
    /// Stops at the first one whose target can't be found, so nothing lands in the wrong place.
    private func run(_ commands: [SpokenCommand], utterance: String, spans: [SpeechSpan]) async {
        let rev = document.revision
        let before = document.text
        var context = contextBundle(for: utterance)
        context.project = ""

        var working = before
        var ops: [DocumentOp] = []
        var notes: [String] = []
        var failure: String?
        let recent = recentPassages(in: before)
        // Paragraph numbers refer to the margin as it was when you spoke, so those go first.
        let ordered = commands.filter { if case .deleteParagraphs = $0 { return true } else { return false } }
            + commands.filter { if case .deleteParagraphs = $0 { return false } else { return true } }
        let exact = commands.compactMap { command -> String? in
            if case .exact(let text, _) = command { return text } else { return nil }
        }

        for command in ordered {
            switch CommandPlanner.resolve(command, document: working, recent: recent) {
            case .edit(let op, let note):
                guard let next = try? DocumentModel.apply(op: op, to: working) else {
                    failure = "Couldn't apply: \(note)"
                    break
                }
                working = next
                ops.append(op)
                notes.append(note)
            case .edits(let batch, let note):
                var next = working
                for op in batch {
                    guard let applied = try? DocumentModel.apply(op: op, to: next) else {
                        failure = "Couldn't apply: \(note)"
                        break
                    }
                    next = applied
                }
                if failure != nil { break }
                working = next
                ops.append(contentsOf: batch)
                notes.append(note)
            case .rewrite(let passage, let start, let how):
                if let range = working.range(of: passage) { workingPlace = .range(NSRange(range, in: working)) }
                do {
                    let t0 = Date()
                    let text = try await interpreter.rewrite(passage: passage, how: how, document: working, context: context)
                    if Task.isCancelled { return }
                    appendDebug("Rewrite \(Int(Date().timeIntervalSince(t0) * 1000))ms → \(text.prefix(200))")
                    guard let op = CommandPlanner.rewriteOp(passage: passage, start: start, text: text, in: working),
                          let next = try? DocumentModel.apply(op: op, to: working) else {
                        failure = "Couldn't apply the rewrite"
                        break
                    }
                    working = next
                    ops.append(op)
                    notes.append("Rewrote “\(passage.prefix(30))” · \(how)")
                } catch {
                    failure = error.localizedDescription
                }
            case .notFound(let message):
                failure = message
            }
            if failure != nil { break }
        }
        if Task.isCancelled { return }

        appendDebug("Command ops: \(Self.describeOps(ops))" + (failure.map { " · stopped: \($0)" } ?? ""))
        var appliedChange = false
        if !ops.isEmpty {
            switch document.apply(ops: ops, expectedRevision: rev) {
            case .applied:
                appliedChange = landed(before: before, note: notes.joined(separator: " · "), speech: utterance, spans: spans, exact: exact)
            case .stale:
                failure = "The draft changed while this was being written, so nothing was changed"
            case .failed(let reason):
                failure = reason
            }
        }
        if !appliedChange, answer == nil, let failure {
            answer = AnswerCard(kind: .notDone, message: failure)
        }
        let note = ((appliedChange ? notes : []) + [failure].compactMap { $0 }).joined(separator: " · ")
        logTurn(utterance: utterance, spans: spans, intent: appliedChange ? .edit : .discuss, ops: ops,
                note: "[\(Self.modeLabel(commands))] " + note, documentBefore: before, documentAfter: document.text)
        pushTurn(UtteranceTurn(transcript: utterance, intent: .edit, explanation: note,
                               outcome: appliedChange ? .applied : .failed, spans: spans))
    }

    /// Names in the draft plus the speaker's own name, for Whisper's spelling.
    private func speakerVocabulary() -> [String] {
        var words = TextLocator.names(in: document.text)
        let profile = ContextStore.shared.content(ContextStore.shared.url(ContextStore.profileName))
        if let r = profile.range(of: #"(?im)^\s*-?\s*Name:\s*([^\n(]+)"#, options: .regularExpression) {
            let name = profile[r].replacingOccurrences(of: #"(?i)^\s*-?\s*Name:\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !words.contains(name) { words.append(name) }
        }
        return words
    }

    /// Paragraphs the last change touched, newest first, if the draft is still what it left.
    private func recentPassages(in document: String) -> [String] {
        guard let change = lastChange, change.after == document else { return [] }
        let paragraphs = DocumentParagraphs.split(document)
        return change.changes
            .map(\.index)
            .sorted(by: >)
            .compactMap { paragraphs.indices.contains($0) ? paragraphs[$0].text : nil }
    }

    static func modeLabel(_ commands: [SpokenCommand]) -> String {
        var seen: [String] = []
        for mode in commands.map(\.mode) where !seen.contains(mode) { seen.append(mode) }
        return seen.joined(separator: " + ")
    }

    /// Highlights for the transcript: what's being located and what goes in.
    static func spans(for commands: [SpokenCommand], in utterance: String) -> [SpeechSpan] {
        var spans: [SpeechSpan] = []
        func add(_ role: SpanRole, _ quote: String?) {
            guard let quote, !quote.isEmpty, quote.lowercased() != "it" else { return }
            spans.append(SpeechSpan(role: role, quote: quote))
        }
        for command in commands {
            switch command {
            case .replace(let target, let with):
                add(.target, target); add(.payload, with)
            case .delete(let target):
                add(.target, target)
            case .deleteParagraphs:
                if let r = utterance.range(of: #"(?i)(?:the\s+)?[\w\s,¶]*?paragraphs?[\s\d,¶and]*"#, options: .regularExpression) {
                    add(.target, String(utterance[r]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
                }
            case .rewrite(let target, let how):
                add(.target, target); add(.constraint, how)
            case .exact(let text, let position):
                add(.payload, text)
                switch position {
                case .end: break
                case .after(let a), .before(let a): add(.target, a)
                }
            }
        }
        return spans
    }

    private func act(on utterance: String, spans: [SpeechSpan], selection: NSRange? = nil, recheckHint: String? = nil) async {
        let rev = document.revision
        let docSnapshot = document.text
        let context = contextBundle(for: utterance)

        do {
            let plan = SpanPlanner.plan(spans: spans, utterance: utterance, document: docSnapshot)
            appendDebug("Plan \(plan.reason) intent=\(plan.intent.rawValue) needsProse=\(plan.needsModelProse)")

            let empty = docSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let forced = EscapePhrases.forceIntent(utterance, documentIsEmpty: empty)
            let recent = turns.prefix(3).map(\.transcript)

            let response: InterpreterResponse
            if !plan.needsModelProse {
                response = InterpreterResponse(intent: plan.intent, assistantMessage: plan.assistantMessage, ops: plan.ops, spans: spans)
            } else {
                let t0 = Date()
                var proposed = try await interpreter.proposeEdits(
                    utterance: utterance, document: docSnapshot, revision: rev, context: context,
                    lastAssistant: lastAssistantMessage, recentUtterances: recent,
                    spans: spans, forcedIntent: forced, retryHint: recheckHint
                )
                if Task.isCancelled { return }
                appendDebug("Writer \(Int(Date().timeIntervalSince(t0) * 1000))ms: \(proposed.rawJSON ?? "(none)")")
                var reconciled = SpanPlanner.reconcile(response: proposed, spans: spans, utterance: utterance, document: docSnapshot, plan: plan)
                if reconciled.copiedInstruction {
                    appendDebug("Retry: writer copied an ask/aside into the document")
                    let hint = "Your text copied the ask/aside wording into the document. Do what the ask says; text must be written from the words and gist spans only."
                    proposed = try await interpreter.proposeEdits(
                        utterance: utterance, document: docSnapshot, revision: rev, context: context,
                        lastAssistant: lastAssistantMessage, recentUtterances: recent,
                        spans: spans, forcedIntent: forced, retryHint: hint
                    )
                    if Task.isCancelled { return }
                    appendDebug("Writer retry: \(proposed.rawJSON ?? "(none)")")
                    reconciled = SpanPlanner.reconcile(response: proposed, spans: spans, utterance: utterance, document: docSnapshot, plan: plan)
                }
                if let note = reconciled.note { appendDebug("Reconcile: \(note)") }
                response = reconciled.response
            }

            appendDebug("Apply intent=\(response.intent.rawValue) ops=\(Self.describeOps(response.ops))")
            apply(response: response, expectedRev: rev, utterance: utterance, documentBefore: docSnapshot,
                  recordRequest: recheckHint == nil, modelReplied: plan.needsModelProse, selection: selection)
        } catch {
            guard !Task.isCancelled else { return }
            let message = error.localizedDescription
            answer = AnswerCard(kind: .failed, message: message)
            appendDebug("LLM error: \(message)")
            logTurn(utterance: utterance, spans: spans, intent: nil, ops: [], note: message,
                    documentBefore: docSnapshot, documentAfter: docSnapshot)
            pushTurn(UtteranceTurn(transcript: utterance, explanation: message, outcome: .failed, spans: spans))
        }
    }

    private func apply(response: InterpreterResponse, expectedRev: Int, utterance: String, documentBefore: String,
                       recordRequest: Bool = true, modelReplied: Bool = false, selection: NSRange? = nil) {
        if let message = response.assistantMessage, !message.isEmpty {
            lastAssistantMessage = message
        }
        var ops = response.ops.filter { $0.op != .noDocumentChange }
        if ops.count == 1, ops[0].op == .append, let text = ops[0].text {
            if let merged = CommandPlanner.mergeAppend(text, into: document.text) {
                if merged != ops[0] { appendDebug("Merged append → \(Self.describeOps([merged]))") }
                ops = [merged]
            } else {
                appendDebug("Append dropped: everything in it is already in the draft")
                ops = []
            }
        }

        func finish(intent: IntentKind, note: String, outcome: UtteranceTurn.Outcome, ops logged: [DocumentOp]) {
            logTurn(utterance: utterance, spans: response.spans, intent: intent, ops: logged, note: note,
                    documentBefore: documentBefore, documentAfter: document.text)
            pushTurn(UtteranceTurn(transcript: utterance, intent: intent, explanation: note, outcome: outcome, spans: response.spans))
            if recordRequest, response.spans.contains(where: { $0.role != .meta }) {
                requests.append(ReviewRequest(utterance: utterance, spans: response.spans))
                if requests.count > 20 { requests.removeFirst(requests.count - 20) }
            }
        }

        if response.intent == .discuss || ops.isEmpty {
            let note = response.assistantMessage ?? "Nothing to change in the document"
            if modelReplied, response.intent == .discuss, let reply = response.assistantMessage, !reply.isEmpty {
                answer = AnswerCard(kind: .answer, message: reply)
                discussedRange = selection ?? discussed(request: Request(text: utterance, spans: response.spans), spans: response.spans)
            }
            finish(intent: .discuss, note: note, outcome: .discussed, ops: [])
            return
        }

        switch document.apply(ops: ops, expectedRevision: expectedRev) {
        case .applied:
            if landed(before: documentBefore, note: Self.explain(ops), speech: utterance, spans: response.spans) {
                finish(intent: response.intent, note: Self.explain(ops), outcome: .applied, ops: ops)
            } else {
                finish(intent: response.intent, note: "Refused: would change locked wording", outcome: .failed, ops: ops)
            }
        case .stale:
            answer = AnswerCard(kind: .notDone, message: "The draft changed while this was being written, so nothing was changed.")
            finish(intent: response.intent, note: "Skipped — the document changed while I was writing", outcome: .failed, ops: ops)
        case .failed(let reason):
            answer = AnswerCard(kind: .notDone, message: reason)
            finish(intent: response.intent, note: reason, outcome: .failed, ops: ops)
        }
    }

    // MARK: - Local commands

    private func clearDocument(heard: String) {
        let before = document.text
        let op = DocumentOp(op: .delete, target: "whole_document")
        let result = document.apply(ops: [op], expectedRevision: document.revision)
        appendDebug("Local command clear → \(result)")
        if result == .applied {
            cancelReview()
            requests = []
            locks = []
            approved = []
            recordChange(before: before, note: "Cleared the document")
            noteInHistory(heard, "Cleared the whole draft")
        }
        logTurn(utterance: heard, spans: [], intent: .edit, ops: [op], note: "Cleared the document",
                documentBefore: before, documentAfter: document.text)
    }

    // MARK: - Reviewing the whole draft (local engine)

    private func cancelReview() {
        reviewTask?.cancel()
        reviewTask = nil
    }

    private func forgetUndoneRequest() {
        if lastChangeWasReview {
            lastChangeWasReview = false
        } else if !requests.isEmpty {
            requests.removeLast()
        }
    }

    private var isQuiet: Bool {
        isOpen && unsentText.isEmpty && !speechActive && sttInFlight == 0 && work.isEmpty
    }

    private func scheduleReview() {
        reviewTask?.cancel()
        guard !usesCloud else { return }
        let delay = reviewDelay
        reviewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.isQuiet else { return }
            await self.runReview()
        }
    }

    /// Checks the whole draft after a quiet moment: structure, requests whose labels can be verified,
    /// and a per-paragraph look for stray instructions and spoken filler. Lands as one undoable change.
    private func runReview() async {
        let doc = document.text
        let rev = document.revision
        guard !doc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let recent = DraftReview.recent(requests)
        let t0 = Date()

        if let missing = DraftReview.latestMissingWords(document: doc, requests: recent),
           !recheckedRequests.contains(missing.id) {
            recheckedRequests.insert(missing.id)
            appendDebug("Review: last request's wording isn't in the draft — asking the writer again")
            reviewTask = nil
            isWorking = true
            await act(on: missing.utterance, spans: missing.spans,
                      recheckHint: "This request is not reflected in CURRENT_DOCUMENT yet. Apply it now, in the right place.")
            isWorking = !work.isEmpty
            return
        }

        let lint = DocumentLint.check(doc)
        var fixes = lint.fixes + DraftReview.unmetReplacements(document: doc, requests: recent)
        var working = DraftReview.ops(for: fixes, document: doc, requests: recent).result

        var checked: [String] = []
        var deleted = false
        for paragraph in DraftReview.paragraphsToCheck(working, alreadyChecked: checkedParagraphs) {
            let verdict: ParagraphVerdict
            do {
                verdict = try await interpreter.checkParagraph(paragraph, document: working)
            } catch {
                if !Task.isCancelled { appendDebug("Review error: \(error.localizedDescription)") }
                break
            }
            guard !Task.isCancelled else { return }
            checked.append(paragraph)
            appendDebug("Review paragraph → \(verdict.kind.rawValue) · \"\(paragraph.prefix(60))\" → \"\(verdict.clean.prefix(60))\"")
            if let fix = DraftReview.fix(for: paragraph, verdict: verdict, requests: recent) {
                if fix.replace.isEmpty {
                    if deleted { continue }
                    deleted = true
                }
                fixes.append(fix)
                working = DraftReview.ops(for: [fix], document: working, requests: recent).result
            }
        }
        guard !Task.isCancelled else { return }
        reviewTask = nil

        if let move = DraftReview.moveAboveSignOff(working) { fixes.append(move) }
        let planned = DraftReview.ops(for: fixes, document: doc, requests: recent)
        if !planned.rejected.isEmpty { appendDebug("Review rejected: \(planned.rejected.joined(separator: "; "))") }
        appendDebug("Review \(Int(Date().timeIntervalSince(t0) * 1000))ms · \(recent.count) requests · hints=\(lint.hints) · \(planned.applied.count) fixes")

        guard rev == document.revision, isQuiet else {
            appendDebug("Review dropped — draft or speech changed meanwhile")
            return
        }
        for paragraph in checked { checkedParagraphs.insert(DocumentLint.normalize(paragraph)) }
        guard !planned.ops.isEmpty else { return }

        let result = document.apply(ops: planned.ops, expectedRevision: rev)
        appendDebug("Review apply → \(result) · \(Self.describeOps(planned.ops))")
        guard result == .applied else { return }
        var reasons: [String] = []
        for fix in planned.applied where !reasons.contains(fix.why) { reasons.append(fix.why) }
        let note = "Tidied: " + reasons.prefix(3).joined(separator: ", ")
        guard landed(before: doc, note: note, speech: nil, spans: []) else { return }
        for paragraph in DocumentLint.paragraphs(document.text) { checkedParagraphs.insert(DocumentLint.normalize(paragraph)) }
        lastChangeWasReview = true
        logTurn(utterance: "(review)", spans: [], intent: .edit, ops: planned.ops, note: note,
                documentBefore: doc, documentAfter: document.text)
        pushTurn(UtteranceTurn(transcript: "Checked the draft", intent: .edit, explanation: note, outcome: .applied))
    }

    private func pushTurn(_ turn: UtteranceTurn) {
        turns.insert(turn, at: 0)
        if turns.count > 12 { turns = Array(turns.prefix(12)) }
    }

    // MARK: - Descriptions for logs and history

    private static func explain(_ ops: [DocumentOp]) -> String {
        guard let op = ops.first else { return "No change" }
        switch op.op {
        case .append: return "Added a new passage"
        case .insert: return "Inserted text"
        case .replace:
            if let anchor = op.anchor { return "Replaced “\(anchor.prefix(40))”" }
            if let target = op.target { return "Rewrote the \(target.replacingOccurrences(of: "_", with: " "))" }
            return "Replaced a span"
        case .delete:
            if op.target == "whole_document" { return "Cleared the document" }
            return "Removed text"
        case .move: return "Moved text without changing it"
        case .noDocumentChange: return "No change"
        }
    }

    private static func describeOps(_ ops: [DocumentOp]) -> String {
        if ops.isEmpty { return "[]" }
        return ops.map { op in
            var bits = [op.op.rawValue]
            if let t = op.text { bits.append("text=\(t.prefix(80))") }
            if let a = op.anchor { bits.append("anchor=\(a.prefix(40))") }
            if let t = op.target { bits.append("target=\(t)") }
            return bits.joined(separator: " ")
        }.joined(separator: " | ")
    }

    // MARK: - Logs

    private func logTurn(
        utterance: String,
        spans: [SpeechSpan],
        intent: IntentKind?,
        ops: [DocumentOp],
        note: String,
        documentBefore: String,
        documentAfter: String,
        model: String? = nil
    ) {
        TurnLog.write([
            "utterance": utterance,
            "model": model ?? interpreter.modelName,
            "spans": spans.map { ["role": $0.role.rawValue, "quote": $0.quote] },
            "intent": intent?.rawValue ?? "",
            "ops": ops.map { op -> [String: String] in
                var d = ["op": op.op.rawValue]
                if let t = op.text { d["text"] = t }
                if let a = op.anchor { d["anchor"] = a }
                if let t = op.target { d["target"] = t }
                return d
            },
            "note": note,
            "document_before": String(documentBefore.prefix(1500)),
            "document_after": String(documentAfter.prefix(1500))
        ])
    }

    func appendDebug(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        debugLog = "[\(stamp)] \(line)\n" + debugLog
        if debugLog.count > 12_000 {
            debugLog = String(debugLog.prefix(12_000))
        }
        TimingLog.write(line)
    }
}
