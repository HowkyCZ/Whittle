import XCTest
@testable import ScriberCore

final class VoicePhrasesTests: XCTestCase {
    func testOkaySendSendsWhatCameBefore() {
        XCTAssertEqual(VoicePhrases.classify("Make it warmer. Okay, send."), .send("Make it warmer."))
        XCTAssertEqual(VoicePhrases.classify("make it warmer ok send"), .send("make it warmer"))
        XCTAssertEqual(VoicePhrases.classify("Make it warmer. Okay. Sent."), .send("Make it warmer."))
        XCTAssertEqual(VoicePhrases.classify("Okay, send."), .send(""))
        XCTAssertEqual(VoicePhrases.classify("Send it."), .send(""))
    }

    func testSendInsideDictationIsJustText() {
        XCTAssertEqual(VoicePhrases.classify("I'll send it tomorrow."), .append("I'll send it tomorrow."))
        XCTAssertEqual(VoicePhrases.classify("Okay, so send him the deck."), .append("Okay, so send him the deck."))
    }

    func testControlPhrases() {
        XCTAssertEqual(VoicePhrases.classify("Scratch that."), .scratch)
        XCTAssertEqual(VoicePhrases.classify("make it warmer, no, scratch that"), .scratch)
        XCTAssertEqual(VoicePhrases.classify("Undo that."), .undo)
        XCTAssertEqual(VoicePhrases.classify("Redo."), .redo)
        XCTAssertEqual(VoicePhrases.classify("Wait."), .cancel)
    }

    func testExactWording() {
        let speech = "In the second paragraph, after the fundraising line, say exactly we would love your eyes on the plan, then briefly mention that the plan reaches beyond Rotterdam."
        XCTAssertEqual(VoicePhrases.exactWording(in: speech), ["we would love your eyes on the plan"])
        XCTAssertEqual(VoicePhrases.exactWording(in: "Write exactly: “I think you are right.”"), ["I think you are right."])
        XCTAssertTrue(VoicePhrases.asksForExactWording(speech))
        XCTAssertFalse(VoicePhrases.asksForExactWording("make it exactly two lines"))
    }

    func testApprovalReferences() {
        XCTAssertEqual(ApprovalParser.references(in: "Good, the opening works. Now make the ending warmer."), ["the opening"])
        XCTAssertEqual(ApprovalParser.references(in: "I like the last paragraph."), ["the last paragraph"])
        XCTAssertTrue(ApprovalParser.references(in: "Make the opening warmer.").isEmpty)
    }

    func testApprovalParagraph() {
        let doc = "Hi Tomas,\n\nThanks for yesterday.\n\nWe are raising.\n\nBest,\nSam"
        XCTAssertEqual(ApprovalParser.paragraph(for: "the opening", in: doc), 1)
        XCTAssertEqual(ApprovalParser.paragraph(for: "the ending", in: doc), 2)
        XCTAssertEqual(ApprovalParser.paragraph(for: "the second paragraph", in: doc), 1)
    }

    func testLockedWording() {
        let locks = ["Rotterdam alone will not carry it."]
        let before = "We are raising. Rotterdam alone will not carry it."
        XCTAssertEqual(LockedWording.ranges(locks, in: before), [NSRange(location: 16, length: 34)])
        XCTAssertTrue(LockedWording.broken(locks, before: before, after: "We are raising. Rotterdam alone will not carry it. Thanks.").isEmpty)
        XCTAssertEqual(LockedWording.broken(locks, before: before, after: "We are raising. Rotterdam won't carry it."), locks)
    }

    func testSelectionReplacesDeicticTargets() {
        let selected = "I have been turning it over since."
        let commands: [SpokenCommand] = [
            .rewrite(target: "this", how: "warmer"),
            .delete(target: nil),
            .replace(target: "Rotterdam", with: "Aarhus")
        ]
        XCTAssertEqual(SelectionTarget.apply(commands, selection: selected), [
            .rewrite(target: selected, how: "warmer"),
            .delete(target: selected),
            .replace(target: "Rotterdam", with: "Aarhus")
        ])
    }
}

@MainActor
final class DocumentHistoryTests: XCTestCase {
    func testTypingBurstIsOneVersion() {
        let model = DocumentModel()
        let t0 = Date()
        model.userEdited("H", at: t0)
        model.userEdited("Hi", at: t0.addingTimeInterval(0.5))
        model.userEdited("Hi!", at: t0.addingTimeInterval(1))
        XCTAssertEqual(model.version, 1)
        model.userEdited("Hi! Again", at: t0.addingTimeInterval(5))
        XCTAssertEqual(model.version, 2)
        XCTAssertTrue(model.undo())
        XCTAssertEqual(model.text, "Hi!")
    }

    func testUndoRedoThroughAIAndTypedVersions() {
        let model = DocumentModel()
        model.userEdited("One")
        XCTAssertEqual(model.apply(ops: [DocumentOp(op: .append, text: "Two")], expectedRevision: model.revision), .applied)
        XCTAssertTrue(model.undo())
        XCTAssertEqual(model.text, "One")
        XCTAssertTrue(model.canRedo)
        XCTAssertTrue(model.redo())
        XCTAssertEqual(model.text, "One\n\nTwo")
        XCTAssertFalse(model.redo())
    }

    func testNewChangeClearsRedo() {
        let model = DocumentModel()
        model.userEdited("One")
        _ = model.apply(ops: [DocumentOp(op: .append, text: "Two")], expectedRevision: model.revision)
        model.undo()
        model.userEdited("One!")
        XCTAssertFalse(model.canRedo)
    }

    func testDiscardLastChangeSkipsRedo() {
        let model = DocumentModel()
        model.userEdited("Keep this.")
        _ = model.apply(ops: [DocumentOp(op: .replace, text: "Changed.", target: "whole_document")], expectedRevision: model.revision)
        XCTAssertTrue(model.discardLastChange())
        XCTAssertEqual(model.text, "Keep this.")
        XCTAssertFalse(model.canRedo)
    }
}

final class ChangeHighlightTests: XCTestCase {
    func testAddedRangesCoverNewWords() {
        let before = "Thanks.\n\nWe are currently raising money to take the program beyond one cohort."
        let after = "Thanks.\n\nIt is also why timing matters: we are currently raising money to take the program beyond one cohort."
        let ranges = ParagraphDiff.addedRanges(before: before, after: after)
        let ns = after as NSString
        XCTAssertEqual(ranges.map { ns.substring(with: $0) }, ["It is also why timing matters: we"])
    }

    func testNewParagraphIsAddedWhole() {
        let after = "Thanks.\n\nWould you be open to a call?"
        let ranges = ParagraphDiff.addedRanges(before: "Thanks.", after: after)
        XCTAssertEqual(ranges.map { (after as NSString).substring(with: $0) }, ["Would you be open to a call?"])
    }

    func testCloudEditApprovedIsOptional() {
        let old = #"{"ops":[],"reply":"","could_not_do":[]}"#
        XCTAssertEqual(CloudEdit.parse(old)?.approved, [])
        let new = #"{"ops":[],"reply":"","could_not_do":[],"approved":["p1"]}"#
        XCTAssertEqual(CloudEdit.parse(new)?.approved, ["p1"])
    }
}

final class ClipSequencerTests: XCTestCase {
    func testResultsComeOutInSpokenOrder() {
        var sequencer = ClipSequencer<String>()
        // "okay, send" (clip 2) finishes before the sentence before it (clip 1).
        XCTAssertEqual(sequencer.finish(2, "Okay, send."), [])
        XCTAssertFalse(sequencer.hasHandedOut(through: 1))
        XCTAssertEqual(sequencer.finish(1, "Make it warmer."), ["Make it warmer.", "Okay, send."])
        XCTAssertTrue(sequencer.hasHandedOut(through: 2))
        XCTAssertEqual(sequencer.finish(3, "Next."), ["Next."])
    }

    func testStaleAndResetClips() {
        var sequencer = ClipSequencer<String>()
        _ = sequencer.finish(1, "a")
        XCTAssertEqual(sequencer.finish(1, "again"), [])
        sequencer.reset()
        XCTAssertEqual(sequencer.finish(1, "fresh"), ["fresh"])
    }
}

final class SpeechGateTests: XCTestCase {
    /// Feeds `seconds` of frames at one loudness (43 ms frames, as the mic delivers them).
    private func feed(_ gate: inout SpeechGate, _ energy: Float, seconds: Double) -> [SpeechGate.Event] {
        (0..<Int(seconds * 1000 / 43)).map { _ in gate.feed(energy, ms: 43) }.filter { $0 != .none }
    }

    func testQuietSpeakerIsHeard() {
        // The levels from the log: background around 0.0015, speech around 0.005, under the old fixed 0.008.
        var gate = SpeechGate()
        XCTAssertEqual(feed(&gate, 0.0015, seconds: 2), [])
        XCTAssertLessThan(gate.startThreshold, 0.005)
        XCTAssertEqual(feed(&gate, 0.005, seconds: 1), [.started])
        // Softer words mid-sentence keep the clip going.
        XCTAssertEqual(feed(&gate, 0.0035, seconds: 1), [])
        XCTAssertEqual(feed(&gate, 0.005, seconds: 1), [])
        let end = feed(&gate, 0.0015, seconds: 2)
        guard case .ended(let voiced)? = end.first else { return XCTFail("clip didn't end: \(end)") }
        XCTAssertGreaterThan(voiced, 2800)
    }

    func testNoisyRoomSettlesAndThenOnlySpeechCounts() {
        var gate = SpeechGate()
        // Steady noise may open one clip before the background is learned, but it must end on its own.
        _ = feed(&gate, 0.012, seconds: 6)
        XCTAssertFalse(gate.inSpeech, "stuck in a clip on steady noise")
        XCTAssertEqual(feed(&gate, 0.012, seconds: 5), [])
        XCTAssertEqual(feed(&gate, 0.06, seconds: 1), [.started])
    }

    func testLongSpeechWithGapsDoesNotRaiseTheBar() {
        var gate = SpeechGate()
        _ = feed(&gate, 0.0015, seconds: 2)
        XCTAssertEqual(feed(&gate, 0.006, seconds: 0.5), [.started])
        // 10 s of talking: words with short gaps between them.
        for _ in 0..<10 {
            XCTAssertEqual(feed(&gate, 0.006, seconds: 0.7), [])
            XCTAssertEqual(feed(&gate, 0.0016, seconds: 0.3), [])
        }
        XCTAssertTrue(gate.inSpeech)
        XCTAssertLessThan(gate.startThreshold, 0.006)
    }

    func testDigitalSilenceKeepsAFloorUnderTheBar() {
        var gate = SpeechGate()
        _ = feed(&gate, 0, seconds: 2)
        XCTAssertEqual(gate.startThreshold, gate.minimumStart)
        XCTAssertEqual(feed(&gate, 0.001, seconds: 1), [])
    }

    func testForceEnd() {
        var gate = SpeechGate()
        XCTAssertNil(gate.forceEnd())
        _ = feed(&gate, 0.0015, seconds: 1)
        _ = feed(&gate, 0.01, seconds: 0.5)
        XCTAssertNotNil(gate.forceEnd())
        XCTAssertFalse(gate.inSpeech)
    }
}

final class ClipboardTextTests: XCTestCase {
    func testParagraphsBecomeDivsWithoutStyling() {
        let html = ClipboardText.html("Hi Lena,\n\nThanks for <the> intro & more.\n\nBest,\nSam\n")
        XCTAssertEqual(html, "<meta charset=\"utf-8\"><div>Hi Lena,</div><div><br></div><div>Thanks for &lt;the&gt; intro &amp; more.</div><div><br></div><div>Best,</div><div>Sam</div>")
        XCTAssertFalse(html.contains("font"))
        XCTAssertFalse(html.contains("style"))
    }
}

final class SoundBandsTests: XCTestCase {
    private func tone(_ hz: Double, amplitude: Float, count: Int = 512, rate: Double = 16_000) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    private func noise(_ amplitude: Float, count: Int = 512) -> [Float] {
        (0..<count).map { _ in Float.random(in: -amplitude...amplitude) }
    }

    func testEachBandHearsItsOwnPitch() {
        let bands = SoundBands()
        for _ in 0..<60 { _ = bands.levels(noise(0.001), sampleRate: 16_000) }
        let low = bands.levels(tone(180, amplitude: 0.05), sampleRate: 16_000)
        XCTAssertEqual(low.firstIndex(of: low.max()!), 0, "\(low)")
        let mid = bands.levels(tone(1800, amplitude: 0.05), sampleRate: 16_000)
        XCTAssertEqual(mid.firstIndex(of: mid.max()!), 2, "\(mid)")
        let hiss = bands.levels(tone(5000, amplitude: 0.05), sampleRate: 16_000)
        XCTAssertEqual(hiss.firstIndex(of: hiss.max()!), 3, "\(hiss)")
    }

    func testBackgroundReadsAsSilence() {
        let bands = SoundBands()
        var last: [Double] = []
        for _ in 0..<60 { last = bands.levels(noise(0.002), sampleRate: 16_000) }
        XCTAssertTrue(last.allSatisfy { $0 < 0.15 }, "\(last)")
    }
}

final class NoiseFilterTests: XCTestCase {
    private func clip(_ rms: Float, room: Float = 0.0004) -> NoiseFilter.Loudness {
        NoiseFilter.Loudness(rms: rms, background: room)
    }

    func testTappingIsTooQuietToTranscribe() {
        // Logged noise clips (taps, knocks) that Whisper turned into "Thank you." and "The End".
        for rms: Float in [0.0010, 0.0014, 0.0016, 0.0019, 0.0020] {
            XCTAssertTrue(NoiseFilter.isTooQuiet(clip(rms)), "\(rms)")
        }
    }

    func testQuietestLoggedSpeechIsKept() {
        for rms: Float in [0.0052, 0.0058, 0.0065] {
            XCTAssertFalse(NoiseFilter.isTooQuiet(clip(rms)), "\(rms)")
        }
        // A quiet microphone in a silent room: soft, but far above the background.
        XCTAssertFalse(NoiseFilter.isTooQuiet(clip(0.0020, room: 0.0001)))
    }

    func testThankYouFromNoiseIsDropped() {
        XCTAssertTrue(NoiseFilter.isPhantom("Thank you.", clip(0.0034)))
        XCTAssertTrue(NoiseFilter.isPhantom("Thank you.", clip(0.0049, room: 0.0015)))
        XCTAssertTrue(NoiseFilter.isPhantom("I’m going to go to the next video.", clip(0.0040)))
        XCTAssertTrue(NoiseFilter.isPhantom("-", clip(0.0040)))
    }

    func testThankYouSpokenAloudIsKept() {
        XCTAssertFalse(NoiseFilter.isPhantom("Thank you.", clip(0.0092)))
    }

    func testRealWordsAreNeverPhantoms() {
        XCTAssertFalse(NoiseFilter.isPhantom("Haven founders.", clip(0.0035)))
        XCTAssertFalse(NoiseFilter.isPhantom("Thank you for connecting me with Lena.", clip(0.0035)))
        XCTAssertFalse(NoiseFilter.isPhantom("Okay, send.", clip(0.0035)))
    }
}
