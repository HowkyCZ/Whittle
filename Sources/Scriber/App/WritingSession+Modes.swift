import Foundation
import ScriberCore

/// Write talks to the text, Structure plans it, Review has agents comment on it.
enum WritingMode: String, CaseIterable, Identifiable {
    case write, structure, review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write: return "Write"
        case .structure: return "Structure"
        case .review: return "Review"
        }
    }

    var summary: String {
        switch self {
        case .write: return "Talk to the text"
        case .structure: return "Plan sections, no prose"
        case .review: return "Agents comment, you approve"
        }
    }
}

/// Speaking over a selection, word for word: the selection shows struck through and what's said appears after it.
struct Dictation: Equatable {
    /// The selection, in the draft as it was when dictation started.
    var range: NSRange
    var original: String
    var spoken = ""

    /// The draft as shown while dictating, and where the struck and the new text are.
    func preview(live: String) -> (text: String, struck: NSRange, spoken: NSRange) {
        let words = [spoken, live].filter { !$0.isEmpty }.joined(separator: " ")
        let ns = original as NSString
        guard !words.isEmpty else { return (original, range, NSRange(location: NSMaxRange(range), length: 0)) }
        let insert = " " + words
        let text = ns.replacingCharacters(in: NSRange(location: NSMaxRange(range), length: 0), with: insert)
        return (text, range, NSRange(location: NSMaxRange(range) + 1, length: (words as NSString).length))
    }
}

extension WritingSession {
    // MARK: - Switching

    func switchMode(to new: WritingMode) {
        guard new != mode else { return }
        cancelDictation()
        if mode == .review { leaveReview() }
        answer = nil
        discussedRange = nil
        mode = new
        appendDebug("Mode → \(new.title)")
        switch new {
        case .write: break
        case .structure: enterStructure()
        case .review: runReview()
        }
    }

    /// A new draft starts in Write with no plan and no comments.
    func resetModes() {
        cancelDictation()
        leaveReview()
        outlineTask?.cancel()
        outlineCheckTask?.cancel()
        outline = Outline()
        outlineUndo = []
        freshSections = []
        mode = .write
    }

    /// The text the draft editor shows: the draft, or the draft with dictation in progress.
    var editorText: String {
        dictation?.preview(live: liveWords).text ?? document.text
    }

    /// Something busy that the mic tile shows as the quill writing.
    var isBusy: Bool { isWorking || outlineBusy > 0 || !runningAgents.isEmpty || agentIsReplying }

    /// After any change lands: the plan's paragraph numbers and ticks are re-read, comments re-found.
    func draftChanged() {
        if mode == .review { relocateComments() }
        guard !outline.isEmpty else { return }
        outlineCheckTask?.cancel()
        outlineCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled, !self.outline.isCurrent(for: self.document.text) else { return }
            self.runOutline(.check)
        }
    }

    // MARK: - Structure

    private func enterStructure() {
        let draft = document.text
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if outline.isEmpty {
            if hasText { runOutline(.derive) }
        } else if hasText, !outline.isCurrent(for: draft) {
            runOutline(.check)
        }
    }

    /// Structure calls run one at a time, in the order they were asked.
    func runOutline(_ task: OutlineTask) {
        guard codex.isAvailable else {
            answer = AnswerCard(kind: .failed, message: CodexEditor.Failure.notInstalled.localizedDescription)
            return
        }
        if case .edit = task, showCommandCards {
            showCommandCards = false
            UserDefaults.standard.set(true, forKey: "commandCardsDone")
        }
        outlineBusy += 1
        let previous = outlineTask
        outlineTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if !Task.isCancelled { await self.performOutline(task) }
            self.outlineBusy -= 1
        }
    }

    private func performOutline(_ task: OutlineTask) async {
        var draft = document.text
        // Plan edits move written text, so the paragraph numbers have to match the draft first.
        if case .edit = task, !outline.isEmpty, !outline.isCurrent(for: draft),
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await performOutline(.check)
            draft = document.text
        }
        if task == .check, outline.isCurrent(for: draft) { return }
        let started = Date()
        let speech: String
        if case .edit(let said) = task { speech = said } else { speech = "" }
        appendDebug("Structure → \(task == .check ? "check" : task == .derive ? "derive" : "“\(speech)”")")
        do {
            let (reply, raw) = try await codex.outline(task, draft: draft, outline: outline,
                                                       context: contextBundle(for: speech.isEmpty ? draft : speech))
            guard !Task.isCancelled else { return }
            appendDebug("Structure \(Int(Date().timeIntervalSince(started) * 1000))ms: \(raw)")
            applyOutline(reply, task: task, draft: draft, speech: speech)
        } catch {
            guard !Task.isCancelled else { return }
            appendDebug("Structure error: \(error.localizedDescription)")
            if task != .check { answer = AnswerCard(kind: .failed, message: error.localizedDescription) }
        }
    }

    private func applyOutline(_ reply: OutlineReply, task: OutlineTask, draft: String, speech: String) {
        var (merged, added, write) = outline.merging(reply, draft: draft)

        if task == .check {
            // A check only reads the draft: everything but paragraphs and ticks stays as the writer planned it.
            var checked = outline
            for index in checked.sections.indices {
                guard let fresh = merged.sections.first(where: { $0.id == checked.sections[index].id }) else {
                    checked.sections[index].paragraphs = []
                    continue
                }
                checked.sections[index].paragraphs = fresh.paragraphs
                for p in checked.sections[index].points.indices {
                    let id = checked.sections[index].points[p].id
                    checked.sections[index].points[p].covered = fresh.points.first { $0.id == id }?.covered ?? false
                }
            }
            checked.checkedDraft = draft
            if document.text == draft { outline = checked } else { draftChanged() }
            return
        }

        guard document.text == draft else {
            // The draft changed while the plan was being worked out: keep the plan, read the paragraphs again.
            merged.checkedDraft = nil
            outline = merged
            draftChanged()
            return
        }

        let previous = outline
        var movedDraft = false
        // Moving a written section moves its paragraphs in the draft, as one version.
        if let (text, moved) = Outline.regroup(draft, sections: merged.sections) {
            let op = DocumentOp(op: .replace, text: text, target: "whole_document")
            if document.apply(ops: [op], expectedRevision: document.revision) == .applied {
                merged.sections = moved
                merged.checkedDraft = text
                movedDraft = true
            }
        }
        outline = merged
        if task != .derive, movedDraft || previous != merged { outlineUndo.append((previous, movedDraft)) }
        if movedDraft {
            recordChange(before: draft, note: "Moved sections")
            noteInHistory(speech, "Moved sections in the outline")
        }

        if !added.isEmpty, task != .derive {
            freshSections.formUnion(added)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                self?.freshSections.subtract(added)
            }
        }
        let reply = reply.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty { answer = AnswerCard(kind: .outline, message: reply) }
        if !write.isEmpty { writeSections(write) }
    }

    /// Steps the plan back one change; if that change moved paragraphs, the draft goes back too.
    func undoOutline() {
        guard let last = outlineUndo.popLast() else { return }
        if last.movedDraft { _ = document.undo() }
        outline = last.outline
        if !outline.isCurrent(for: document.text) { draftChanged() }
    }

    /// Writes sections with the strong model, then shows them in Write.
    func writeSections(_ ids: [String]) {
        let draft = document.text
        guard let text = outline.writeRequest(for: ids, draft: draft) else { return }
        let first = outline.sections.first { ids.contains($0.id) }
        var place: WorkingPlace = .end
        if let first, let index = outline.sections.firstIndex(where: { $0.id == first.id }),
           let next = outline.sections[(index + 1)...].first(where: \.isWritten), let p = next.paragraphs.min() {
            place = .insert(before: p)
        }
        switchMode(to: .write)
        enqueue(Request(text: text, spans: [], selection: nil, forceCloud: true, place: place))
    }

    func writeTheRest() {
        writeSections(outline.unwritten.map(\.id))
    }

    // MARK: - Review

    /// Every enabled agent reads the draft at once; comments appear as each one finishes.
    func runReview() {
        reviewTasks.forEach { $0.cancel() }
        reviewTasks = []
        comments = []
        selectedComment = nil
        talkingTo = nil
        runningAgents = []
        let draft = document.text
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard codex.isAvailable else {
            answer = AnswerCard(kind: .failed, message: CodexEditor.Failure.notInstalled.localizedDescription)
            return
        }
        let context = contextBundle(for: draft)
        for agent in agents where agent.enabled {
            runningAgents.insert(agent.id)
            let started = Date()
            reviewTasks.append(Task { [weak self] in
                guard let self else { return }
                do {
                    let review = try await self.codex.review(as: agent, draft: draft, context: context)
                    guard !Task.isCancelled else { return }
                    self.appendDebug("Review · \(agent.name) \(Int(Date().timeIntervalSince(started) * 1000))ms · \(review.comments.count) comments")
                    if self.mode == .review, self.document.text == draft {
                        let found = review.comments.compactMap { item -> ReviewComment? in
                            guard let range = ReviewText.locate(item.quote, in: draft), !item.comment.isEmpty else {
                                self.appendDebug("Review · \(agent.name): couldn't find “\(item.quote)”")
                                return nil
                            }
                            return ReviewComment(agentID: agent.id, quote: item.quote, range: range, message: item.comment)
                        }
                        self.comments = (self.comments + found).sorted { $0.range.location < $1.range.location }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.appendDebug("Review · \(agent.name) error: \(error.localizedDescription)")
                }
                self.runningAgents.remove(agent.id)
            })
        }
    }

    func leaveReview() {
        reviewTasks.forEach { $0.cancel() }
        reviewTasks = []
        runningAgents = []
        comments = []
        selectedComment = nil
        talkingTo = nil
        agentIsReplying = false
    }

    func agent(for comment: ReviewComment) -> ReviewAgent? {
        agents.first { $0.id == comment.agentID }
    }

    func selectComment(_ id: UUID?) {
        selectedComment = selectedComment == id ? nil : id
    }

    /// Approve, or take an approval back.
    func toggleApproval(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[index].state = comments[index].state == .approved ? .open : .approved
        selectedComment = nil
    }

    func dismissComment(_ id: UUID) {
        comments.removeAll { $0.id == id }
        if selectedComment == id { selectedComment = nil }
        if talkingTo == id { talkingTo = nil }
    }

    /// Opens the conversation with the comment's agent above the voice box.
    func startConversation(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        if comments[index].state == .open || comments[index].state == .approved { comments[index].state = .talking }
        talkingTo = id
        selectedComment = id
        focusVoice += 1
    }

    /// What the writer said to the agent; it answers, and can change its mind.
    func replyToAgent(_ text: String) {
        guard let id = talkingTo ?? selectedComment else { return }
        if talkingTo == nil { startConversation(id) }
        guard let index = comments.firstIndex(where: { $0.id == id }), let agent = agent(for: comments[index]) else { return }
        comments[index].thread.append(ReviewMessage(from: .writer, text: text))
        comments[index].state = .talking
        let comment = comments[index]
        let draft = document.text
        let context = contextBundle(for: text)
        agentIsReplying = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.codex.reply(as: agent, to: comment, draft: draft, context: context)
                guard let index = self.comments.firstIndex(where: { $0.id == id }) else { return }
                self.comments[index].thread.append(ReviewMessage(from: .agent, text: reply.reply))
                self.comments[index].conclusion = reply.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
                self.appendDebug("Review · \(agent.name) replied: \(reply.reply) · conclusion: \(reply.conclusion)")
            } catch {
                self.answer = AnswerCard(kind: .failed, message: error.localizedDescription)
            }
            self.agentIsReplying = false
        }
    }

    /// The conversation's conclusion joins the batch for the editor.
    func concludeConversation() {
        guard let id = talkingTo, let index = comments.firstIndex(where: { $0.id == id }) else { return }
        if comments[index].conclusion.isEmpty {
            comments.remove(at: index)
        } else {
            comments[index].state = .concluded
        }
        talkingTo = nil
        selectedComment = nil
    }

    func dismissConversation() {
        guard let id = talkingTo else { return }
        dismissComment(id)
    }

    var commentsForEditor: Int { comments.filter(\.isForEditor).count }

    /// Approved comments and agreed conclusions go to the editor as one change, and Review ends.
    func sendReviewToEditor() {
        guard let text = ReviewText.editorRequest(comments, agents: agents, draft: document.text) else { return }
        switchMode(to: .write)
        enqueue(Request(text: text, spans: [], selection: nil, forceCloud: true))
    }

    /// After an edit in Review, comments follow their passages; ones whose passage is gone are dropped.
    private func relocateComments() {
        let draft = document.text
        comments = comments.compactMap { comment in
            var comment = comment
            guard let range = ReviewText.locate(comment.quote, in: draft) else { return nil }
            comment.range = range
            return comment
        }
    }

    func setAgent(_ id: String, enabled: Bool) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].enabled = enabled
    }

    func addAgent(name: String, brief: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let used = Set(agents.map(\.color))
        let color = ReviewAgent.palette.first { !used.contains($0) } ?? ReviewAgent.palette[agents.count % ReviewAgent.palette.count]
        agents.append(ReviewAgent(id: UUID().uuidString, name: name, brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
                                  color: color))
    }

    static func savedAgents() -> [ReviewAgent] {
        guard let data = UserDefaults.standard.data(forKey: "reviewAgents"),
              let agents = try? JSONDecoder().decode([ReviewAgent].self, from: data), !agents.isEmpty else {
            return ReviewAgent.defaults
        }
        return ReviewAgent.updatingColors(agents)
    }

    static func saveAgents(_ agents: [ReviewAgent]) {
        if let data = try? JSONEncoder().encode(agents) { UserDefaults.standard.set(data, forKey: "reviewAgents") }
    }

    // MARK: - Word for word over a selection

    var canDictateOverSelection: Bool {
        mode == .write && dictation == nil && !isWorking && currentSelection() != nil
    }

    /// ⌥Space or the mic at the selection: what's said next replaces the selection exactly as spoken.
    func startDictation() {
        guard canDictateOverSelection, let selection = currentSelection() else { return }
        answer = nil
        discussedRange = nil
        dictation = Dictation(range: selection.range, original: document.text)
        if isMicPaused { toggleMicPause() }
        appendDebug("Word for word over “\(selection.text.prefix(60))”")
    }

    /// Only "okay, send" is a command; everything else is the new text.
    func hearWordForWord(_ fragment: String) {
        guard dictation != nil else { return }
        if case .send(let text) = VoicePhrases.classify(fragment) {
            if !text.isEmpty { dictation?.spoken += (dictation?.spoken.isEmpty == true ? "" : " ") + text }
            send()
            return
        }
        dictation?.spoken += (dictation?.spoken.isEmpty == true ? "" : " ") + fragment
    }

    /// Replace: the selection becomes what was said, as one version.
    func commitDictation() {
        guard let dictation else { return }
        self.dictation = nil
        let spoken = dictation.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = document.text
        guard !spoken.isEmpty, before == dictation.original else { return }
        let after = (before as NSString).replacingCharacters(in: dictation.range, with: spoken)
        let op = DocumentOp(op: .replace, text: after, target: "whole_document")
        guard document.apply(ops: [op], expectedRevision: document.revision) == .applied else { return }
        recordChange(before: before, note: "Dictated over the selection")
        let replaced = (before as NSString).substring(with: dictation.range)
        noteInHistory("(dictated word for word over a selection)", "Replaced “\(replaced.prefix(120))” with “\(spoken.prefix(120))”")
        appendDebug("Word for word → “\(spoken)”")
    }

    /// Cancel or Esc: the selection stays as it was.
    func cancelDictation() {
        guard dictation != nil else { return }
        dictation = nil
        appendDebug("Word for word cancelled")
    }
}
