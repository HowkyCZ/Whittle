import XCTest
@testable import ScriberCore

final class ParagraphDiffTests: XCTestCase {
    func testSplitNumbersParagraphsLikeTheApplier() throws {
        let doc = "Hi Tomas,\n\nThanks for yesterday.\n\nBest,\nSam"
        let paragraphs = DocumentParagraphs.split(doc)
        XCTAssertEqual(paragraphs.map(\.text), ["Hi Tomas,", "Thanks for yesterday.", "Best,", "Sam"])

        let second = try DocumentModel.resolveStructuralRange("paragraph_2", in: doc)
        XCTAssertEqual(String(doc[second]), paragraphs[1].text)
        XCTAssertEqual(NSRange(second, in: doc), paragraphs[1].range)
    }

    func testReplacingParagraph() {
        let doc = "One.\n\nTwo.\n\nThree."
        XCTAssertEqual(DocumentParagraphs.replacing(1, with: "  Deux. ", in: doc), "One.\n\nDeux.\n\nThree.")
        XCTAssertEqual(DocumentParagraphs.replacing(7, with: "x", in: doc), doc)
    }

    func testClearingParagraphRemovesItsBreak() {
        let doc = "One.\n\nTwo.\n\nThree."
        XCTAssertEqual(DocumentParagraphs.replacing(1, with: "", in: doc), "One.\n\nThree.")
        XCTAssertEqual(DocumentParagraphs.replacing(2, with: " ", in: doc), "One.\n\nTwo.")
        XCTAssertEqual(DocumentParagraphs.replacing(0, with: "", in: "Only."), "")
    }

    func testAppending() {
        XCTAssertEqual(DocumentParagraphs.appending("First.", to: ""), "First.")
        XCTAssertEqual(DocumentParagraphs.appending(" Second. ", to: "First.\n"), "First.\n\nSecond.")
        XCTAssertEqual(DocumentParagraphs.appending("  ", to: "First."), "First.")
    }

    func testRewordedParagraphIsModifiedWithWordRuns() {
        let before = "Thanks for yesterday.\n\nWe are currently raising money to grow."
        let after = "Thanks for yesterday.\n\nIt is also why the timing matters: we are currently raising money to grow."
        let changes = ParagraphDiff.changes(before: before, after: after)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].index, 1)
        XCTAssertEqual(changes[0].kind, .modified([
            DiffRun(text: "We", kind: .removed),
            DiffRun(text: "It is also why the timing matters: we", kind: .added),
            DiffRun(text: "are currently raising money to grow.", kind: .same)
        ]))
    }

    func testAppendedParagraphIsInserted() {
        let changes = ParagraphDiff.changes(before: "One.", after: "One.\n\nA brand new paragraph.")
        XCTAssertEqual(changes, [ParagraphChange(index: 1, kind: .inserted)])
    }

    func testFullRewriteReadsAsNewText() {
        let changes = ParagraphDiff.changes(
            before: "Thanks for meeting me yesterday.",
            after: "Would you be open to a short call next week?"
        )
        XCTAssertEqual(changes, [ParagraphChange(index: 0, kind: .inserted)])
    }

    func testUnchangedDocumentHasNoChanges() {
        XCTAssertTrue(ParagraphDiff.changes(before: "Same.\n\nText.", after: "Same.\n\nText.").isEmpty)
    }
}
