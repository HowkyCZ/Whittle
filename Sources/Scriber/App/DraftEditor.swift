import AppKit
import SwiftUI
import ScriberCore

/// The draft's geometry: gutter 24 + 28 gap, so tints never touch the numbers.
enum DraftLayout {
    static let gutterLeft: CGFloat = 16
    static let gutterWidth: CGFloat = 24
    static let gutterGap: CGFloat = 28
    static let textLeft: CGFloat = gutterLeft + gutterWidth + gutterGap
    static let textRight: CGFloat = 44
    static let top: CGFloat = 32
    static let bottom: CGFloat = 20
    static let paragraphGap: CGFloat = 20
    /// Review: the draft on its sheet, no margin numbers.
    static let reviewSide: CGFloat = 44
    static let reviewTop: CGFloat = 40
}

/// A text view that can find the lines a range sits on, for drawing marks behind the text.
class MarkedTextView: NSTextView {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// One rect per line around the glyphs of `range`, in view coordinates, without trailing whitespace.
    func bands(for range: NSRange, verticalInset: CGFloat, padding: CGFloat) -> [NSRect] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        let ns = string as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard clamped.length > 0 else { return [] }
        let glyphs = layout.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            var chars = layout.characterRange(forGlyphRange: part, actualGlyphRange: nil)
            while chars.length > 0,
                  let scalar = UnicodeScalar(ns.character(at: NSMaxRange(chars) - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                chars.length -= 1
            }
            guard chars.length > 0 else { return }
            let trimmed = layout.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            let bounds = layout.boundingRect(forGlyphRange: trimmed, in: container)
            rects.append(NSRect(
                x: origin.x + bounds.minX - padding,
                y: origin.y + lineRect.minY + verticalInset,
                width: bounds.width + padding * 2,
                height: lineRect.height - verticalInset * 2
            ))
        }
        return rects
    }

    /// The line fragment holding the character at `index`, in view coordinates.
    func lineRect(at index: Int) -> NSRect {
        guard let layout = layoutManager else { return .zero }
        let length = (string as NSString).length
        guard length > 0 else {
            let extra = layout.extraLineFragmentRect
            return extra.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        let glyph = layout.glyphIndexForCharacter(at: min(index, length - 1))
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The baseline of the line holding the character at `index`, in view coordinates.
    func baseline(at index: Int) -> CGFloat {
        guard let layout = layoutManager, (string as NSString).length > 0 else { return 0 }
        let glyph = layout.glyphIndexForCharacter(at: min(index, (string as NSString).length - 1))
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return textContainerOrigin.y + line.minY + layout.location(forGlyphAt: glyph).y
    }

    static func fill(_ rects: [NSRect], _ color: NSColor, radius: CGFloat) {
        color.setFill()
        for rect in rects { NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill() }
    }

    static func textKit1(_ make: (NSTextContainer) -> MarkedTextView) -> MarkedTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = make(container)
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.insertionPointColor = .scriberInk
        view.selectedTextAttributes = [.backgroundColor: NSColor.scriberSelection]
        return view
    }
}

// MARK: - The draft

/// What's drawn on top of the plain text: never part of it, never in the way of selecting or typing.
struct EditorMarks: Equatable {
    var isWorking = false
    var working: WorkingPlace?
    var flash: ChangeFlash?
    var discussed: NSRange?
    var locks: [String] = []
    var approved: Set<String> = []
    /// Review: the draft on a sheet with each comment's passage in its agent's colour.
    var reviewLayout = false
    var comments: [CommentMark] = []
    var dictation: DictationMark?
    /// The place named in what's being said ("paragraph two"), outlined until it's sent.
    var pointed: NSRange?
}

/// A review comment's passage: tinted with a 2pt underline, darker when selected, struck through once approved.
struct CommentMark: Equatable {
    var id: UUID
    var range: NSRange
    var color: NSColor
    var selected: Bool
    var approved: Bool
}

/// Word-for-word dictation: the selection struck through, what's said after it.
struct DictationMark: Equatable {
    var struck: NSRange
    var spoken: NSRange
}

final class DraftTextView: MarkedTextView {
    var marks = EditorMarks() {
        didSet { if marks != oldValue { marksChanged(from: oldValue) } }
    }
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var canUndo: () -> Bool = { false }
    var canRedo: () -> Bool = { false }
    var onComment: ((UUID) -> Void)?
    var onDictate: (() -> Void)?
    var canDictate: () -> Bool = { false }
    private let micBubble = SelectionMicBubble()

    static let bodyFont = Typeface.nsDocument()
    static let body = LineSetting.attributes(font: bodyFont, color: .scriberBody, lineHeight: Typeface.documentLineHeight)
    /// Blank lines between paragraphs are set short, so a paragraph break reads as a 20pt gap.
    static let blank: [NSAttributedString.Key: Any] = {
        var attributes = body
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = DraftLayout.paragraphGap
        style.maximumLineHeight = DraftLayout.paragraphGap
        attributes[.paragraphStyle] = style
        attributes[.baselineOffset] = 0
        return attributes
    }()
    static let boldFont = Typeface.nsStyled(bodyFont, bold: true, italic: false)
    static let italicFont = Typeface.nsStyled(bodyFont, bold: false, italic: true)
    static let boldItalicFont = Typeface.nsStyled(bodyFont, bold: true, italic: true)
    /// The serif's own bullet is small; this one reads as a list at a glance.
    static let bulletFont = Typeface.nsDocument(bodyFont.pointSize * 1.3)
    static let bulletOffset = ((body[.baselineOffset] as? CGFloat) ?? 0) - bodyFont.pointSize * 0.09
    /// A list item hangs: wrapped lines line up with the text after the bullet or number.
    static func listStyle(prefix: String) -> NSParagraphStyle {
        let style = ((body[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        let width = prefix == DraftFormat.bullet
            ? ("•" as NSString).size(withAttributes: [.font: bulletFont]).width + (" " as NSString).size(withAttributes: [.font: bodyFont]).width
            : (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
        style.headIndent = ceil(width)
        return style
    }
    /// Room after locked wording for its lock icon.
    static let lockRoom: CGFloat = 19
    static let approvedCheck = PixelIcon.check.image(color: .scriberMuted)
    static let lockIcon = PixelIcon.lock.image(color: .scriberExactLine)

    /// How long a change glows before it's plain text again.
    static let flashHold: TimeInterval = 1.5
    static let flashFade: TimeInterval = 0.7

    /// Bold and italic in the text, and their markers, which are laid out as nothing (see `MarkerHider`).
    private(set) var formatRuns: [DraftFormat.Run] = []
    private var hiddenMarkers: [NSRange] = []
    let markerHider = MarkerHider()

    private var workingStart = Date()
    private var timer: Timer?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    override var textContainerOrigin: NSPoint {
        marks.reviewLayout ? NSPoint(x: DraftLayout.reviewSide, y: DraftLayout.reviewTop) : NSPoint(x: DraftLayout.textLeft, y: DraftLayout.top)
    }

    // MARK: Clicks and keys

    /// In Review a click on a highlighted passage opens its comment.
    override func mouseDown(with event: NSEvent) {
        if marks.reviewLayout, !marks.comments.isEmpty, let layout = layoutManager, let container = textContainer {
            let point = convert(event.locationInWindow, from: nil)
            let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            var fraction: CGFloat = 0
            let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            if glyphRect.insetBy(dx: -1, dy: -3).contains(inContainer) {
                let index = layout.characterIndexForGlyph(at: glyph)
                // The smallest passage wins when they overlap.
                if let hit = marks.comments.filter({ NSLocationInRange(index, $0.range) }).min(by: { $0.range.length < $1.range.length }) {
                    onComment?(hit.id)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    /// ⌥Space over a selection: say the replacement, word for word.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option, canDictate() {
            onDictate?()
            return
        }
        super.keyDown(with: event)
    }

    /// The small mic next to a selection in Write.
    func updateMicBubble() {
        let range = selectedRange()
        guard isEditable, range.length > 0, canDictate(), let layout = layoutManager, let container = textContainer else {
            micBubble.isHidden = true
            return
        }
        if micBubble.superview !== self {
            addSubview(micBubble)
            micBubble.onClick = { [weak self] in self?.onDictate?() }
        }
        let ns = string as NSString
        var last = NSMaxRange(range) - 1
        while last > range.location, let scalar = UnicodeScalar(ns.character(at: last)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { last -= 1 }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: last, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let side = SelectionMicBubble.side
        var origin = NSPoint(x: rect.maxX + 6, y: rect.midY - side / 2)
        if origin.x + side > bounds.width - 8 {
            origin = NSPoint(x: min(rect.maxX, bounds.width - 8) - side, y: rect.maxY + 4)
        }
        micBubble.frame = NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: NSSize(width: side, height: side))
        micBubble.isHidden = false
    }

    // MARK: Undo goes through the draft's history

    /// Copy and cut give the same plain text + HTML as Done, so a pasted selection keeps its paragraphs.
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        WritingSession.copyToClipboard((string as NSString).substring(with: range))
    }

    override func cut(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, shouldChangeText(in: range, replacementString: "") else { return }
        copy(sender)
        replaceCharacters(in: range, with: "")
        didChangeText()
    }

    // MARK: Lists, bold and italic while typing

    /// "- " or "* " at the start of a line becomes a bullet.
    override func insertText(_ insert: Any, replacementRange: NSRange) {
        let text = (insert as? String) ?? (insert as? NSAttributedString)?.string ?? ""
        let caret = selectedRange()
        if text == " ", replacementRange.location == NSNotFound, caret.length == 0 {
            let ns = string as NSString
            let lineStart = ns.lineRange(for: NSRange(location: caret.location, length: 0)).location
            let typed = ns.substring(with: NSRange(location: lineStart, length: caret.location - lineStart))
            if typed == "-" || typed == "*" {
                replace(NSRange(location: lineStart, length: caret.location - lineStart), with: DraftFormat.bullet)
                return
            }
        }
        super.insertText(insert, replacementRange: replacementRange)
    }

    /// Return in a list starts the next item; Return on an empty item ends the list.
    override func insertNewline(_ sender: Any?) {
        let caret = selectedRange()
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: caret.location, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        if caret.length == 0, let prefix = DraftFormat.listPrefix(of: line),
           caret.location >= lineRange.location + (prefix as NSString).length {
            if line.trimmingCharacters(in: .whitespaces) == prefix.trimmingCharacters(in: .whitespaces) {
                replace(NSRange(location: lineRange.location, length: (line as NSString).length), with: "")
                return
            }
            if let next = DraftFormat.nextPrefix(after: line) {
                replace(caret, with: "\n" + next)
                return
            }
        }
        super.insertNewline(sender)
    }

    /// A click never leaves the caret inside a hidden marker.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if ranges.count == 1, let new = ranges.first?.rangeValue, new.length == 0,
           let marker = hiddenMarkers.first(where: { new.location > $0.location && new.location < NSMaxRange($0) }) {
            let forward = new.location >= selectedRange().location
            ranges = [NSValue(range: NSRange(location: forward ? NSMaxRange(marker) : marker.location, length: 0))]
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    override func moveRight(_ sender: Any?) {
        if !stepOverMarkers(forward: true) { super.moveRight(sender) }
    }

    override func moveLeft(_ sender: Any?) {
        if !stepOverMarkers(forward: false) { super.moveLeft(sender) }
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        if !extendOverMarkers(forward: true) { super.moveRightAndModifySelection(sender) }
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        if !extendOverMarkers(forward: false) { super.moveLeftAndModifySelection(sender) }
    }

    /// The fixed end and the moving end of a selection made with Shift-arrows, while the draft has markers.
    private var extending: (anchor: Int, head: Int)?

    /// AppKit's caret movement gets lost on glyphs laid out as nothing, so in a draft with bold or italic the
    /// caret steps by characters, past markers: one press is one visible step.
    private func stepOverMarkers(forward: Bool) -> Bool {
        let caret = selectedRange()
        guard caret.length == 0, !hiddenMarkers.isEmpty else { return false }
        setSelectedRange(NSRange(location: step(from: caret.location, forward: forward), length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }

    private func extendOverMarkers(forward: Bool) -> Bool {
        guard !hiddenMarkers.isEmpty else { return false }
        let selection = selectedRange()
        var anchor = forward ? selection.location : NSMaxRange(selection)
        if let extending, NSRange(location: min(extending.anchor, extending.head), length: abs(extending.head - extending.anchor)) == selection {
            anchor = extending.anchor
        }
        let head = anchor == selection.location ? NSMaxRange(selection) : selection.location
        let moved = step(from: head, forward: forward)
        extending = (anchor, moved)
        setSelectedRange(NSRange(location: min(anchor, moved), length: abs(moved - anchor)))
        scrollRangeToVisible(NSRange(location: moved, length: 0))
        return true
    }

    /// One visible character on from `location`, skipping markers.
    private func step(from location: Int, forward: Bool) -> Int {
        let ns = string as NSString
        var location = location
        while let marker = hiddenMarkers.first(where: { forward ? $0.location == location : NSMaxRange($0) == location }) {
            location = forward ? NSMaxRange(marker) : marker.location
        }
        if forward, location < ns.length {
            location = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: location))
        } else if !forward, location > 0 {
            location = ns.rangeOfComposedCharacterSequence(at: location - 1).location
        }
        return location
    }

    /// Deleting next to a marker deletes the visible letter, and the last letter of a bold word takes its markers.
    override func deleteBackward(_ sender: Any?) {
        if deleteFormatted(forward: false) { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if deleteFormatted(forward: true) { return }
        super.deleteForward(sender)
    }

    private func deleteFormatted(forward: Bool) -> Bool {
        var caret = selectedRange()
        if caret.length > 0 {
            // A selection that is exactly a run's text takes the run's markers too.
            guard let run = formatRuns.first(where: { $0.content == caret }) else { return false }
            replace(run.range, with: "")
            return true
        }
        if let marker = hiddenMarkers.first(where: { (forward ? $0.location : NSMaxRange($0)) == caret.location }) {
            caret.location = forward ? NSMaxRange(marker) : marker.location
            setSelectedRange(caret)
        }
        let letter = forward ? caret.location : caret.location - 1
        if let run = formatRuns.first(where: { $0.content == NSRange(location: letter, length: 1) }) {
            replace(run.range, with: "")
            return true
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEditable, window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": toggle(.bold); return true
            case "i": toggle(.italic); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘B / ⌘I: wraps the selection (or the word at the caret), or unwraps it when it's already that style.
    func toggle(_ style: DraftFormat.Inline) {
        let ns = string as NSString
        var range = selectedRange()
        if let run = formatRuns.first(where: { $0.style == style && NSIntersectionRange($0.range, range) == range
                                                && (range.length > 0 || NSLocationInRange(range.location, $0.content) || range.location == NSMaxRange($0.content)) }) {
            let inner = ns.substring(with: run.content)
            replace(run.range, with: inner, select: NSRange(location: run.range.location, length: (inner as NSString).length))
            return
        }
        if range.length == 0 {
            let word = selectionRange(forProposedRange: range, granularity: .selectByWord)
            guard word.length > 0, ns.substring(with: word).contains(where: \.isLetter) else { NSSound.beep(); return }
            range = word
        }
        // Spaces at the ends stay outside the markers.
        while range.length > 0, ns.substring(with: NSRange(location: range.location, length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            range.location += 1; range.length -= 1
        }
        while range.length > 0, ns.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            range.length -= 1
        }
        let inner = ns.substring(with: range)
        guard !inner.isEmpty, !inner.contains("\n") else { NSSound.beep(); return }
        let marker = style == .bold ? "**" : "*"
        replace(range, with: marker + inner + marker, select: NSRange(location: range.location + marker.count, length: (inner as NSString).length))
    }

    /// A change made by the editor itself, through the same path as typing so the draft hears about it.
    private func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(select ?? NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    @objc func undo(_ sender: Any?) { onUndo?() }
    @objc func redo(_ sender: Any?) { onRedo?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canUndo()
        case #selector(redo(_:)): return canRedo()
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Styling

    /// The text is plain; this sets its look and leaves room after locked wording for the lock.
    func restyle() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        storage.setAttributes(Self.body, range: full)
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            if ns.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty, enclosing.length > 0 {
                storage.setAttributes(Self.blank, range: enclosing)
            }
        }
        ns.enumerateSubstrings(in: full, options: .byParagraphs) { line, range, _, _ in
            guard let line, let prefix = DraftFormat.listPrefix(of: line) else { return }
            storage.addAttribute(.paragraphStyle, value: Self.listStyle(prefix: prefix), range: range)
            if prefix == DraftFormat.bullet {
                storage.addAttributes([.font: Self.bulletFont, .baselineOffset: Self.bulletOffset],
                                      range: NSRange(location: range.location, length: 1))
            }
        }
        let runs = DraftFormat.runs(in: storage.string)
        for run in runs.sorted(by: { $0.style == .bold && $1.style == .italic }) {
            switch run.style {
            case .bold:
                storage.addAttribute(.font, value: Self.boldFont, range: run.content)
            case .italic:
                // Italic inside bold stays bold.
                storage.enumerateAttribute(.font, in: run.content) { value, range, _ in
                    let bold = (value as? NSFont) == Self.boldFont
                    storage.addAttribute(.font, value: bold ? Self.boldItalicFont : Self.italicFont, range: range)
                }
            }
            for marker in run.markers { storage.addAttribute(.draftMarker, value: true, range: marker) }
        }
        formatRuns = runs
        hiddenMarkers = runs.flatMap(\.markers)
        for range in LockedWording.ranges(marks.locks, in: storage.string) where range.length > 0 {
            storage.addAttribute(.kern, value: Self.lockRoom, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        }
        storage.endEditing()
        typingAttributes = Self.body
        applyStrikes()
        // The margin numbers sit outside the lines AppKit redraws after an edit.
        needsDisplay = true
    }

    /// Struck-through text (approved comments, the selection being dictated over) without touching the text.
    private func applyStrikes() {
        guard let layout = layoutManager else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        for key in [NSAttributedString.Key.strikethroughStyle, .strikethroughColor, .foregroundColor] {
            layout.removeTemporaryAttribute(key, forCharacterRange: full)
        }
        func strike(_ range: NSRange, line: NSColor, text: NSColor) {
            let range = NSIntersectionRange(range, full)
            guard range.length > 0 else { return }
            layout.addTemporaryAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: line,
                                           .foregroundColor: text], forCharacterRange: range)
        }
        for comment in marks.comments where comment.approved {
            strike(comment.range, line: comment.color, text: .scriberMuted)
        }
        if let dictation = marks.dictation {
            strike(dictation.struck, line: .scriberExactLine, text: NSColor(hex: 0x8A6A84))
        }
    }

    private func marksChanged(from old: EditorMarks) {
        if marks.reviewLayout != old.reviewLayout { invalidateTextContainerOrigin() }
        if marks.locks != old.locks { restyle() } else if marks.comments != old.comments || marks.dictation != old.dictation { applyStrikes() }
        if marks.isWorking, !old.isWorking { workingStart = Date() }
        updateBottomRoom()
        needsDisplay = true
        updateTimer()
        updateCaret()
    }

    /// Extra room under the text while a new paragraph is being written there.
    private func updateBottomRoom() {
        let writingAtEnd = marks.isWorking && (marks.working == .end || string.isEmpty)
        let room = writingAtEnd ? Typeface.documentLineHeight * 3 + DraftLayout.paragraphGap + 12 : DraftLayout.bottom
        let inset = marks.reviewLayout
            ? NSSize(width: DraftLayout.reviewSide, height: (DraftLayout.reviewTop + room) / 2)
            : NSSize(width: (DraftLayout.textLeft + DraftLayout.textRight) / 2, height: (DraftLayout.top + room) / 2)
        if textContainerInset != inset {
            textContainerInset = inset
            sizeToFit()
        }
    }

    // MARK: Animation

    private var flashActive: Bool {
        guard let flash = marks.flash, flash.after == string else { return false }
        return Date().timeIntervalSince(flash.start) < Self.flashHold + Self.flashFade
    }

    private func updateTimer() {
        if marks.isWorking || flashActive {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        if !marks.isWorking, !flashActive {
            timer?.invalidate()
            timer = nil
        }
        setNeedsDisplay(visibleRect)
    }

    /// 0…1: a quick bloom, a hold, then an eased fade.
    static func flashLevel(_ t: TimeInterval) -> CGFloat {
        if t < 0 { return 0 }
        if t < 0.18 { return CGFloat(t / 0.18) }
        if t < flashHold { return 1 }
        let x = min(1, (t - flashHold) / flashFade)
        return CGFloat(1 - x * x * (3 - 2 * x))
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let text = string
        let paragraphs = DocumentParagraphs.split(text)
        let now = Date()

        if let discussed = marks.discussed {
            Self.fill(bands(for: discussed, verticalInset: 3.5, padding: 2), .scriberDiscussed, radius: 3)
        }
        if let pointed = marks.pointed, !marks.isWorking {
            let bands = self.bands(for: pointed, verticalInset: 2, padding: 4)
            Self.fill(bands, .scriberAccent.withAlphaComponent(0.07), radius: 4)
            NSColor.scriberAccent.withAlphaComponent(0.55).setStroke()
            for band in bands {
                let path = NSBezierPath(roundedRect: band.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                path.lineWidth = 1
                path.setLineDash([4, 3], count: 2, phase: 0)
                path.stroke()
            }
        }
        if let flash = marks.flash, flash.after == text {
            let t = now.timeIntervalSince(flash.start)
            let level = Self.flashLevel(t)
            if level > 0 {
                let bloom = max(0, 1 - t / 0.6)
                let color = NSColor.scriberAccent.withAlphaComponent((0.12 + 0.1 * bloom) * level)
                for range in flash.ranges {
                    Self.fill(bands(for: range, verticalInset: 3, padding: 2), color, radius: 3)
                }
            }
        }
        for comment in marks.comments where !comment.approved {
            let bands = self.bands(for: comment.range, verticalInset: 3, padding: 1)
            Self.fill(bands, comment.color.withAlphaComponent(comment.selected ? 0.40 : 0.18), radius: 2)
            comment.color.setFill()
            for band in bands { NSRect(x: band.minX, y: band.maxY - 2, width: band.width, height: 2).fill() }
        }
        if let dictation = marks.dictation {
            Self.fill(bands(for: dictation.struck, verticalInset: 3, padding: 2), .scriberExact, radius: 3)
            let spoken = bands(for: dictation.spoken, verticalInset: 3, padding: 2)
            Self.fill(spoken, .scriberExact.withAlphaComponent(0.6), radius: 3)
            NSColor.scriberExactLine.setFill()
            for band in spoken { NSRect(x: band.minX, y: band.maxY - 1.5, width: band.width, height: 1.5).fill() }
        }
        if marks.isWorking {
            drawWorking(paragraphs, t: now.timeIntervalSince(workingStart))
        }
        if !marks.reviewLayout { drawGutter(paragraphs, in: rect, t: now.timeIntervalSince(workingStart)) }
        drawLocks()
    }

    /// How the place being written is shown.
    private enum WorkingShape {
        /// A light reading across these lines.
        case lines([NSRect], strength: CGFloat)
        /// A seam in the gap where a paragraph will be inserted, at this y.
        case seam(CGFloat)
        /// Placeholder lines for a new paragraph.
        case placeholder([NSRect])
    }

    /// Where the change is being written: the target lines, a seam where a paragraph will be inserted,
    /// placeholder lines for a new one at the end. Unknown place: the whole draft, softly.
    private func workingShape(_ paragraphs: [DocumentParagraph]) -> WorkingShape? {
        guard marks.isWorking else { return nil }
        switch marks.working {
        case .range(let range):
            return .lines(bands(for: range, verticalInset: 3, padding: 2), strength: 1)
        case .paragraph(let index) where paragraphs.indices.contains(index):
            return .lines(bands(for: paragraphs[index].range, verticalInset: 3, padding: 2), strength: 1)
        case .insert(let index) where paragraphs.indices.contains(index):
            let next = lineRect(at: paragraphs[index].range.location)
            var y = next.minY - DraftLayout.paragraphGap / 2
            if index > 0 {
                let previous = lineRect(at: NSMaxRange(paragraphs[index - 1].range) - 1)
                y = (previous.maxY + next.minY) / 2
            }
            return .seam(y)
        case .end:
            return .placeholder(placeholderRects(after: paragraphs.last))
        default:
            if paragraphs.isEmpty { return .placeholder(placeholderRects(after: nil)) }
            return .lines(paragraphs.flatMap { bands(for: $0.range, verticalInset: 3, padding: 2) }, strength: 0.55)
        }
    }

    private func drawWorking(_ paragraphs: [DocumentParagraph], t: TimeInterval) {
        switch workingShape(paragraphs) {
        case .lines(let rects, let strength): sweep(rects, t: t, strength: strength)
        case .seam(let y): seam(at: y, t: t)
        case .placeholder(let rects): sweep(rects, t: t, strength: 1.3, radius: 5.5)
        case nil: break
        }
    }

    /// The area the working highlight covers, whole lines tall.
    private func workingArea() -> [NSRect] {
        let lineHeight = Typeface.documentLineHeight
        switch workingShape(DocumentParagraphs.split(string)) {
        case .lines(let rects, _):
            return rects.map { $0.insetBy(dx: -2, dy: -4) }
        case .seam(let y):
            return [NSRect(x: DraftLayout.textLeft - 4, y: y - 9, width: bounds.width, height: 18)]
        case .placeholder(let rects):
            guard let first = rects.first, let last = rects.last else { return [] }
            return [NSRect(x: DraftLayout.textLeft - 4, y: first.midY - lineHeight / 2, width: bounds.width,
                           height: last.midY - first.midY + lineHeight)]
        case nil:
            return []
        }
    }

    /// The caret disappears while it sits where an edit is being written, so it doesn't look attached to it.
    func updateCaret() {
        var hide = false
        if marks.isWorking, selectedRange().length == 0, let window {
            let onScreen = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
            var caret = convert(window.convertFromScreen(onScreen), from: nil)
            caret.size.width = max(caret.width, 2)
            hide = workingArea().contains { $0.intersects(caret) }
        }
        let color: NSColor = hide ? .clear : .scriberInk
        if insertionPointColor != color { insertionPointColor = color }
    }

    /// A soft tint that breathes, with a bright band travelling through the lines in reading order.
    private func sweep(_ rects: [NSRect], t: TimeInterval, strength: CGFloat = 1, radius: CGFloat = 4) {
        guard !rects.isEmpty else { return }
        let accent = NSColor.scriberAccent
        let breathe = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2 * .pi / 2.4)
        Self.fill(rects, accent.withAlphaComponent((0.05 + 0.035 * breathe) * strength), radius: radius)
        guard !reduceMotion else { return }

        let band: CGFloat = 200
        let speed: CGFloat = 560
        let total = rects.reduce(0) { $0 + $1.width }
        let period = Double((total + band) / speed) + 0.45
        let head = CGFloat(t.truncatingRemainder(dividingBy: period)) * speed - band
        guard let gradient = NSGradient(colorsAndLocations:
            (accent.withAlphaComponent(0), 0),
            (accent.withAlphaComponent(0.16 * strength), 0.6),
            (accent.withAlphaComponent(0.3 * strength), 0.88),
            (accent.withAlphaComponent(0), 1)
        ) else { return }
        var offset: CGFloat = 0
        for rect in rects {
            let local = head - offset
            if local + band > 0, local < rect.width {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
                gradient.draw(in: NSRect(x: rect.minX + local, y: rect.minY, width: band, height: rect.height), angle: 0)
                NSGraphicsContext.restoreGraphicsState()
            }
            offset += rect.width
        }
    }

    /// A glowing line in the gap where a new paragraph will go, with a spark running along it.
    private func seam(at y: CGFloat, t: TimeInterval) {
        let x0 = DraftLayout.textLeft
        let width = bounds.width - DraftLayout.textLeft - DraftLayout.textRight
        let accent = NSColor.scriberAccent
        let line = NSRect(x: x0, y: y - 1, width: width, height: 2)
        Self.fill([line], accent.withAlphaComponent(0.22), radius: 1)

        let pulse = reduceMotion ? 1 : 0.6 + 0.4 * sin(t * 2 * .pi / 1.2)
        Self.fill([NSRect(x: DraftLayout.gutterLeft + DraftLayout.gutterWidth - 7, y: y - 3.5, width: 7, height: 7)],
                  accent.withAlphaComponent(pulse), radius: 3.5)
        guard !reduceMotion,
              let gradient = NSGradient(colors: [accent.withAlphaComponent(0), accent, accent.withAlphaComponent(0)]) else { return }
        let band: CGFloat = 150
        let period = Double((width + band) / 420) + 0.3
        let head = CGFloat(t.truncatingRemainder(dividingBy: period)) * 420 - band
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.8)
        glow.shadowBlurRadius = 7
        glow.set()
        NSBezierPath(rect: NSRect(x: x0, y: y - 8, width: width, height: 16)).addClip()
        gradient.draw(in: NSRect(x: x0 + head, y: y - 1, width: band, height: 2), angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Three lines where a new paragraph is being written.
    private func placeholderRects(after last: DocumentParagraph?) -> [NSRect] {
        var top = DraftLayout.top
        if let last {
            top = lineRect(at: NSMaxRange(last.range) - 1).maxY + DraftLayout.paragraphGap
        }
        let lineHeight = Typeface.documentLineHeight
        let width = bounds.width - DraftLayout.textLeft - DraftLayout.textRight
        return [1.0, 0.93, 0.58].enumerated().map { k, fraction in
            NSRect(x: DraftLayout.textLeft, y: top + CGFloat(k) * lineHeight + (lineHeight - 11) / 2,
                   width: width * fraction, height: 11)
        }
    }

    private func drawGutter(_ paragraphs: [DocumentParagraph], in dirty: NSRect, t: TimeInterval) {
        let font = Typeface.nsUI(11)
        let workingIndex: Int? = {
            guard marks.isWorking else { return nil }
            switch marks.working {
            case .paragraph(let index): return index
            case .range(let range): return paragraphs.firstIndex { NSLocationInRange(range.location, $0.range) }
            default: return nil
            }
        }()
        let pulse = reduceMotion ? 1 : 0.72 + 0.28 * sin(t * 2 * .pi / 1.2)
        let check: NSImage? = Self.approvedCheck

        for (index, paragraph) in paragraphs.enumerated() {
            let line = lineRect(at: paragraph.range.location)
            guard line.maxY >= dirty.minY - 40, line.minY <= dirty.maxY + 40 else { continue }
            let baseline = baseline(at: paragraph.range.location)
            let color = workingIndex == index ? NSColor.scriberAccent.withAlphaComponent(pulse) : NSColor.scriberMuted
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let x = DraftLayout.gutterLeft + DraftLayout.gutterWidth - size.width
            let top = baseline - font.ascender
            label.draw(at: NSPoint(x: x, y: top), withAttributes: attributes)

            if marks.approved.contains(paragraph.text), let check {
                let side: CGFloat = 12
                check.draw(in: NSRect(x: DraftLayout.gutterLeft + DraftLayout.gutterWidth - side, y: top + size.height + 4, width: side, height: side),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    /// Locked wording: a dotted orange underline under the words, then a lock in the room left after them.
    private func drawLocks() {
        guard !marks.locks.isEmpty,
              let lock = Optional(Self.lockIcon)
        else { return }
        NSColor.scriberExactLine.setStroke()
        for range in LockedWording.ranges(marks.locks, in: string) where range.length > 0 {
            let segments = wordSegments(range)
            for segment in segments {
                let dots = NSBezierPath()
                dots.move(to: NSPoint(x: segment.x0 + 1, y: segment.baseline + 4))
                dots.line(to: NSPoint(x: segment.x1, y: segment.baseline + 4))
                dots.lineWidth = 2
                dots.lineCapStyle = .round
                dots.setLineDash([0.001, 4], count: 2, phase: 0)
                dots.stroke()
            }
            if let last = segments.last {
                lock.draw(in: NSRect(x: last.x1 + 4, y: last.baseline - 11, width: 12, height: 12),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    /// Per line: where the words of `range` start and end (by glyph advance, so kerning after them isn't counted).
    private func wordSegments(_ range: NSRange) -> [(x0: CGFloat, x1: CGFloat, baseline: CGFloat)] {
        guard let layout = layoutManager else { return [] }
        let ns = string as NSString
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var segments: [(CGFloat, CGFloat, CGFloat)] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            var last = NSMaxRange(part) - 1
            while last >= part.location,
                  let scalar = UnicodeScalar(ns.character(at: layout.characterIndexForGlyph(at: last))),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                last -= 1
            }
            guard last >= part.location else { return }
            let start = layout.location(forGlyphAt: part.location)
            let end = layout.location(forGlyphAt: last).x + Self.bodyFont.advancement(forCGGlyph: layout.cgGlyph(at: last)).width
            segments.append((origin.x + lineRect.minX + start.x, origin.x + lineRect.minX + end, origin.y + lineRect.minY + start.y))
        }
        return segments
    }
}

/// The draft as a plain text editor: select, type, cut, paste. Numbers, checks, locks and highlights are drawn on top.
struct DraftEditor: NSViewRepresentable {
    @ObservedObject var session: WritingSession
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let view = MarkedTextView.textKit1 { DraftTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: $0) }
        guard let textView = view as? DraftTextView else { return scroll }
        textView.allowsUndo = false
        textView.layoutManager?.delegate = textView.markerHider
        textView.textContainerInset = NSSize(width: (DraftLayout.textLeft + DraftLayout.textRight) / 2,
                                             height: (DraftLayout.top + DraftLayout.bottom) / 2)
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Draft")
        scroll.documentView = textView

        let coordinator = context.coordinator
        coordinator.textView = textView
        // Show the restored version right away, so the next keystroke lands on it.
        textView.onUndo = { [weak session, weak coordinator] in
            session?.undo()
            coordinator?.sync()
        }
        textView.onRedo = { [weak session, weak coordinator] in
            session?.redo()
            coordinator?.sync()
        }
        textView.canUndo = { [weak session] in session?.canUndo ?? false }
        textView.canRedo = { [weak session] in session?.canRedo ?? false }
        textView.onComment = { [weak session] id in session?.selectComment(id) }
        textView.onDictate = { [weak session] in session?.startDictation() }
        textView.canDictate = { [weak session] in session?.canDictateOverSelection ?? false }
        textView.onEscape = onEscape

        scroll.contentView.postsFrameChangedNotifications = true
        coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak scroll, weak textView] _ in
            MainActor.assumeIsolated {
                guard let scroll, let textView else { return }
                textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
                textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: textView.frame.height))
            }
        }
        coordinator.sync()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.textView?.onEscape = onEscape
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: WritingSession
        weak var textView: DraftTextView?
        var frameObserver: NSObjectProtocol?
        private var applyingModel = false
        private var focusRequest = -1
        private var lastWorking: WorkingPlace?
        private var lastFlashStart: Date?

        init(session: WritingSession) {
            self.session = session
        }

        deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingModel, let textView else { return }
            session.userEdited(textView.string)
            textView.restyle()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textView.updateCaret()
            guard !applyingModel else { return }
            session.selection = textView.selectedRange()
            textView.updateMicBubble()
        }

        /// Brings the view up to the session: text changed by an edit or undo, marks, focus.
        func sync() {
            guard let textView else { return }
            let model = session.editorText
            if textView.string != model, !textView.hasMarkedText() {
                replaceText(with: model, in: textView)
            }
            let review = session.mode == .review
            let editable = session.mode == .write && session.dictation == nil
            if textView.isEditable != editable { textView.isEditable = editable }
            textView.marks = EditorMarks(
                isWorking: session.isWorking,
                working: session.workingPlace,
                flash: session.flash,
                discussed: session.discussedRange,
                locks: session.locks,
                approved: review ? [] : session.approved,
                reviewLayout: review,
                comments: review ? session.comments.map { comment in
                    CommentMark(id: comment.id, range: comment.range,
                                color: Theme.nsAgent(session.agent(for: comment)?.color ?? "#6C6975"),
                                selected: comment.id == session.selectedComment,
                                approved: comment.isForEditor)
                } : [],
                dictation: session.dictation.map { dictation in
                    let preview = dictation.preview(live: session.liveWords)
                    return DictationMark(struck: preview.struck, spoken: preview.spoken)
                },
                pointed: session.mode == .write ? session.pointedRange : nil
            )
            textView.updateMicBubble()
            if session.focusRequest != focusRequest, let window = textView.window {
                focusRequest = session.focusRequest
                window.makeFirstResponder(textView)
            }
            reveal(in: textView)
        }

        /// Swaps in only the part that changed, so the caret and scroll position stay put.
        private func replaceText(with model: String, in textView: DraftTextView) {
            let old = textView.string as NSString
            let new = model as NSString
            var prefix = 0
            let shorter = min(old.length, new.length)
            while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            if prefix > 0, prefix < old.length, CFStringIsSurrogateLowCharacter(old.character(at: prefix)) { prefix -= 1 }
            var suffix = 0
            while suffix < shorter - prefix,
                  old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
            let replaced = NSRange(location: prefix, length: old.length - prefix - suffix)
            let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))

            var selection = textView.selectedRange()
            let delta = (replacement as NSString).length - replaced.length
            if selection.location >= NSMaxRange(replaced) {
                selection.location += delta
            } else if NSMaxRange(selection) > replaced.location {
                selection = NSRange(location: prefix + (replacement as NSString).length, length: 0)
            }
            selection.location = min(selection.location, new.length)
            selection.length = min(selection.length, new.length - selection.location)

            applyingModel = true
            textView.textStorage?.replaceCharacters(in: replaced, with: replacement)
            textView.restyle()
            textView.setSelectedRange(selection)
            applyingModel = false
            session.selection = selection
            textView.updateCaret()
        }

        /// Scrolls to where an edit is being written, and to what it changed.
        private func reveal(in textView: DraftTextView) {
            let paragraphs = DocumentParagraphs.split(textView.string)
            if session.isWorking, session.workingPlace != lastWorking {
                lastWorking = session.workingPlace
                switch session.workingPlace {
                case .range(let range): textView.scrollRangeToVisible(range)
                case .paragraph(let index) where paragraphs.indices.contains(index):
                    textView.scrollRangeToVisible(paragraphs[index].range)
                case .insert(let index) where paragraphs.indices.contains(index):
                    textView.scrollRangeToVisible(paragraphs[index].range)
                case .end:
                    textView.scrollToEndOfDocument(nil)
                default: break
                }
            } else if !session.isWorking {
                lastWorking = nil
            }
            if let flash = session.flash, flash.start != lastFlashStart, flash.after == textView.string {
                lastFlashStart = flash.start
                if let first = flash.ranges.first { textView.scrollRangeToVisible(first) }
            }
        }
    }
}

// MARK: - The voice box transcript

final class TranscriptTextView: MarkedTextView {
    var spans: [SpeechSpan] = [] {
        didSet { if spans != oldValue { restyle() } }
    }
    var placeholder = "Listening" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    /// Words still being transcribed, shown faintly at the end; not part of the unsent text.
    var liveRange: NSRange?

    static let font = Typeface.nsUI(14)
    static let lineHeight: CGFloat = 14 * 1.7
    static let base = LineSetting.attributes(font: font, color: .scriberDockText, lineHeight: lineHeight)

    /// Ranges of each labeled run, in order.
    private var runs: [(range: NSRange, role: SpanRole?)] {
        var location = 0
        return SpanAligner.runs(utterance: string, spans: spans).map { run in
            let length = (run.text as NSString).length
            defer { location += length }
            return (NSRange(location: location, length: length), run.role)
        }
    }

    func restyle() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(Self.base, range: full)
        if !spans.isEmpty {
            for run in runs {
                if let role = run.role {
                    storage.addAttributes(role.textAttributes(base: Self.font), range: run.range)
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.scriberMuted, range: run.range)
                }
            }
        }
        if let live = liveRange, NSMaxRange(live) <= full.length {
            storage.addAttribute(.foregroundColor, value: NSColor.scriberMuted.withAlphaComponent(0.75), range: live)
        }
        storage.endEditing()
        typingAttributes = Self.base
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if string.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.scriberMuted]
            let top = textContainerOrigin.y + (Self.lineHeight - Self.font.ascender + Self.font.descender) / 2
            (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: top), withAttributes: attributes)
            return
        }
        guard !spans.isEmpty else { return }
        for run in runs {
            switch run.role {
            case .brief:
                Self.fill(bands(for: run.range, verticalInset: 2.5, padding: 3), .scriberGist, radius: 3)
            case .payload:
                for band in bands(for: run.range, verticalInset: 2.5, padding: 3) {
                    NSColor.scriberExact.setFill()
                    let path = NSBezierPath()
                    let r: CGFloat = 3
                    path.move(to: NSPoint(x: band.minX, y: band.maxY))
                    path.line(to: NSPoint(x: band.minX, y: band.minY + r))
                    path.appendArc(withCenter: NSPoint(x: band.minX + r, y: band.minY + r), radius: r, startAngle: 180, endAngle: 270)
                    path.line(to: NSPoint(x: band.maxX - r, y: band.minY))
                    path.appendArc(withCenter: NSPoint(x: band.maxX - r, y: band.minY + r), radius: r, startAngle: 270, endAngle: 360)
                    path.line(to: NSPoint(x: band.maxX, y: band.maxY))
                    path.close()
                    path.fill()
                    NSColor.scriberExactLine.setFill()
                    NSRect(x: band.minX, y: band.maxY - 1.5, width: band.width, height: 1.5).fill()
                }
            default:
                break
            }
        }
    }
}

/// What was said and not sent yet. Editable: fix a misheard word, or type instead of speaking. Return sends.
struct TranscriptEditor: NSViewRepresentable {
    @ObservedObject var session: WritingSession
    var placeholder: String
    var onEscape: () -> Void

    static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let view = MarkedTextView.textKit1 { TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 24), textContainer: $0) }
        guard let textView = view as? TranscriptTextView else { return scroll }
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.delegate = context.coordinator
        textView.onEscape = onEscape
        textView.setAccessibilityLabel("What you said, not sent yet")
        textView.typingAttributes = TranscriptTextView.base
        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.sync(placeholder: placeholder)

        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak scroll, weak textView] _ in
            MainActor.assumeIsolated {
                guard let scroll, let textView else { return }
                textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: textView.frame.height))
                textView.scrollToEndOfDocument(nil)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.textView?.onEscape = onEscape
        context.coordinator.sync(placeholder: placeholder)
    }

    /// Grows with what was said, up to six lines; measured on a copy so the live view keeps its own layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = context.coordinator.textView, let storage = textView.textStorage else { return nil }
        let width = max(proposal.width ?? 360, 40)
        let copy = NSTextStorage(attributedString: storage)
        let layout = NSLayoutManager()
        copy.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = max(layout.usedRect(for: container).height, TranscriptTextView.lineHeight)
        let limit = TranscriptTextView.lineHeight * Self.maxLines
        nsView.hasVerticalScroller = used > limit + 0.5
        return CGSize(width: width, height: min(used, limit))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: WritingSession
        weak var textView: TranscriptTextView?
        var frameObserver: NSObjectProtocol?
        private var applyingModel = false
        private var focusVoice: Int?

        init(session: WritingSession) {
            self.session = session
        }

        deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingModel, let textView, textView.liveRange == nil else { return }
            session.setUnsent(textView.string)
            textView.restyle()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                session.send()
                return true
            }
            return false
        }

        /// The unsent text, then the words still coming in. While those show, the box isn't editable.
        func sync(placeholder: String) {
            guard let textView else { return }
            textView.placeholder = placeholder
            let unsent = session.unsentText
            let live = session.liveWords
            let display = live.isEmpty ? unsent : (unsent.isEmpty ? live : unsent + " " + live)
            let liveRange = live.isEmpty ? nil
                : NSRange(location: (display as NSString).length - (live as NSString).length, length: (live as NSString).length)
            textView.isEditable = live.isEmpty
            if textView.string != display || textView.liveRange != liveRange, !textView.hasMarkedText() {
                let atEnd = textView.selectedRange().location >= (textView.string as NSString).length
                applyingModel = true
                textView.liveRange = liveRange
                if textView.string != display { textView.string = display }
                if atEnd { textView.setSelectedRange(NSRange(location: (display as NSString).length, length: 0)) }
                applyingModel = false
                textView.restyle()
                textView.scrollToEndOfDocument(nil)
            }
            if textView.string.hasPrefix(unsent) {
                textView.spans = session.unsentSpans
            }
            if focusVoice != session.focusVoice {
                if focusVoice != nil { textView.window?.makeFirstResponder(textView) }
                focusVoice = session.focusVoice
            }
        }
    }
}

/// The mic that appears at the end of a selection in Write: click it (or press ⌥Space) to say the replacement.
final class SelectionMicBubble: NSView {
    static let side: CGFloat = 24
    var onClick: (() -> Void)?
    private let icon = PixelIcon.mic.image(color: .white)

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Say the replacement, word for word (⌥Space)"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Dictate over the selection")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.scriberExactLine.setFill()
        circle.fill()
        let side = CGFloat(PixelIcon.side)
        icon.draw(in: NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

extension NSAttributedString.Key {
    /// A bold or italic marker in the draft: kept in the text, laid out as nothing.
    static let draftMarker = NSAttributedString.Key("WhittleDraftMarker")
}

/// Lays out characters marked `.draftMarker` as null glyphs, so `**bold**` shows as bold with no asterisks.
final class MarkerHider: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        let count = glyphRange.length
        var changed: [NSLayoutManager.GlyphProperty]?
        for i in 0..<count {
            let index = characterIndexes[i]
            guard index < storage.length, storage.attribute(.draftMarker, at: index, effectiveRange: nil) != nil else { continue }
            if changed == nil { changed = Array(UnsafeBufferPointer(start: properties, count: count)) }
            changed?[i] = .null
        }
        guard let changed else { return 0 }
        changed.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        }
        return count
    }
}
