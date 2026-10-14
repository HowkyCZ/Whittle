import XCTest
@testable import ScriberCore

final class ParagraphEditsTests: XCTestCase {
    private let email = "Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nI will be in touch with them soon.\n\nBest,\nSam"

    func testNumberingMatchesMargin() {
        XCTAssertEqual(ParagraphEdits.numbered(email),
                       "[p1] Hi Lena,\n[p2] Thank you for connecting me with Haven Founders.\n[p3] I will be in touch with them soon.\n[p4] Best,\n[p5] Sam")
        XCTAssertEqual(ParagraphEdits.numbered(""), "(empty — use insert_after p0)")
    }

    func testInsertAfterKeepsBreaks() throws {
        let result = try ParagraphEdits.apply([ParagraphOp(op: .insertAfter, id: "p3", text: "It's fine that you can't sponsor us.")],
                                              sent: email, current: email)
        XCTAssertEqual(result, "Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nI will be in touch with them soon.\n\nIt's fine that you can't sponsor us.\n\nBest,\nSam")
    }

    func testReplaceAndDelete() throws {
        let result = try ParagraphEdits.apply([
            ParagraphOp(op: .replace, id: "p2", text: "Thanks for the intro to Haven Founders."),
            ParagraphOp(op: .delete, id: "p3")
        ], sent: email, current: email)
        XCTAssertEqual(result, "Hi Lena,\n\nThanks for the intro to Haven Founders.\n\nBest,\nSam")
    }

    func testSignOffLineBreakSurvivesEditAbove() throws {
        let result = try ParagraphEdits.apply([ParagraphOp(op: .insertBefore, id: "p4", text: "Talk soon.")], sent: email, current: email)
        XCTAssertTrue(result.hasSuffix("soon.\n\nTalk soon.\n\nBest,\nSam"), result)
    }

    func testEmptyDraftAndTop() throws {
        let new = try ParagraphEdits.apply([ParagraphOp(op: .insertAfter, id: "p0", text: "Hi Lena,\n\nThanks!\n\nBest,\nSam")], sent: "", current: "")
        XCTAssertEqual(new, "Hi Lena,\n\nThanks!\n\nBest,\nSam")
        let spaced = try ParagraphEdits.apply([ParagraphOp(op: .insertAfter, id: "p0", text: "Hi Lena,\n\nThanks!\n\nBest,\n\nSam")], sent: "", current: "")
        XCTAssertEqual(spaced, "Hi Lena,\n\nThanks!\n\nBest,\nSam")
        let top = try ParagraphEdits.apply([ParagraphOp(op: .insertAfter, id: "p0", text: "Subject: Intro")], sent: email, current: email)
        XCTAssertTrue(top.hasPrefix("Subject: Intro\n\nHi Lena,"))
    }

    func testRebasesOntoEditsMadeMeanwhile() throws {
        let typed = email.replacingOccurrences(of: "Hi Lena,", with: "Hi Lena,\n\nHope the trip went well.")
        let result = try ParagraphEdits.apply([ParagraphOp(op: .replace, id: "p3", text: "I'll reach out to them this week.")],
                                              sent: email, current: typed)
        XCTAssertEqual(result, "Hi Lena,\n\nHope the trip went well.\n\nThank you for connecting me with Haven Founders.\n\nI'll reach out to them this week.\n\nBest,\nSam")
    }

    func testConflictWhenTargetChangedMeanwhile() {
        let changed = email.replacingOccurrences(of: "I will be in touch", with: "We'll be in touch")
        XCTAssertThrowsError(try ParagraphEdits.apply([ParagraphOp(op: .replace, id: "p3", text: "x")], sent: email, current: changed)) {
            XCTAssertEqual($0 as? ParagraphEdits.Failure, .conflict("p3"))
        }
    }

    func testUnknownParagraph() {
        XCTAssertThrowsError(try ParagraphEdits.apply([ParagraphOp(op: .delete, id: "p9")], sent: email, current: email))
    }

    func testParsesReply() {
        let raw = #"{"ops":[{"op":"insert_after","id":"p3","text":"Hello","from_speech":"say hello"}],"reply":"","could_not_do":[]}"#
        XCTAssertEqual(CloudEdit.parse(raw), CloudEdit(ops: [ParagraphOp(op: .insertAfter, id: "p3", text: "Hello", fromSpeech: "say hello")]))
        XCTAssertEqual(ParagraphEdits.describe(CloudEdit.parse(raw)!.ops), "Added after ¶3")
    }
}
