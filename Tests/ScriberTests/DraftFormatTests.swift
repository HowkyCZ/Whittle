import XCTest
@testable import ScriberCore

final class DraftFormatTests: XCTestCase {
    func testModelMarkdownBecomesTheDraftsOwn() {
        let model = """
        ## Next steps
        - Send the deck by Friday
        * Book the call
          + Ask about the budget
        1) Draft the plan
        2) Share it
        •Tight bullet
        """
        XCTAssertEqual(DraftFormat.normalized(model), """
        **Next steps**
        • Send the deck by Friday
        • Book the call
        • Ask about the budget
        1. Draft the plan
        2. Share it
        • Tight bullet
        """)
        // Already the draft's own, or prose that only looks close: unchanged.
        let own = "• One\n1. Two\n*Italic* at the start, and a - dash mid-line.\n-5 degrees"
        XCTAssertEqual(DraftFormat.normalized(own), own)
        XCTAssertEqual(DraftFormat.normalized(DraftFormat.normalized(model)), DraftFormat.normalized(model))
    }

    func testListsHaveNoBlankLinesInside() {
        let model = "We are raising:\n\n• Expand beyond Rotterdam\n\n• Run two more cohorts\n\n\n1. Draft\n\n2. Share\n\nWould you be open to a call?"
        XCTAssertEqual(DraftFormat.normalized(model),
                       "We are raising:\n• Expand beyond Rotterdam\n• Run two more cohorts\n1. Draft\n2. Share\n\nWould you be open to a call?")
        // Prose paragraphs keep their gaps.
        XCTAssertEqual(DraftFormat.normalized("One.\n\nTwo:\n\nThree."), "One.\n\nTwo:\n\nThree.")
    }

    func testListPrefixes() {
        XCTAssertEqual(DraftFormat.listPrefix(of: "• Item"), "• ")
        XCTAssertEqual(DraftFormat.listPrefix(of: "12. Item"), "12. ")
        XCTAssertNil(DraftFormat.listPrefix(of: "2024. A year"))
        XCTAssertNil(DraftFormat.listPrefix(of: "Plain"))
        XCTAssertEqual(DraftFormat.nextPrefix(after: "• Item"), "• ")
        XCTAssertEqual(DraftFormat.nextPrefix(after: "9. Item"), "10. ")
        XCTAssertNil(DraftFormat.nextPrefix(after: "Plain"))
    }

    func testBoldAndItalicRuns() {
        let text = "We are **raising now** and *soon* closing. A ** lone pair ** and 2*3*4 stay."
        let runs = DraftFormat.runs(in: text)
        let ns = text as NSString
        XCTAssertEqual(runs.map(\.style), [.bold, .italic])
        XCTAssertEqual(runs.map { ns.substring(with: $0.content) }, ["raising now", "soon"])
        XCTAssertEqual(DraftFormat.plain(text), "We are raising now and soon closing. A ** lone pair ** and 2*3*4 stay.")

        let nested = "**Bold with *italic* inside**"
        XCTAssertEqual(DraftFormat.runs(in: nested).map(\.style), [.bold, .italic])
        XCTAssertEqual(DraftFormat.plain(nested), "Bold with italic inside")
        // Runs don't cross lines.
        XCTAssertTrue(DraftFormat.runs(in: "**one\ntwo**").isEmpty)
    }

    func testHTMLForPasting() {
        let draft = """
        Hi Tomas,

        Three things:
        • **Deck** by Friday
        • A call with *Ana*

        1. Draft
        2. Share

        3. Later & more <soon>
        """
        XCTAssertEqual(ClipboardText.html(draft), "<meta charset=\"utf-8\">"
            + "<div>Hi Tomas,</div><div><br></div><div>Three things:</div>"
            + "<ul><li><strong>Deck</strong> by Friday</li><li>A call with <em>Ana</em></li></ul>"
            + "<div><br></div><ol><li>Draft</li><li>Share</li></ol><div><br></div>"
            + "<ol start=\"3\"><li>Later &amp; more &lt;soon&gt;</li></ol>")
        XCTAssertEqual(ClipboardText.plain(draft).components(separatedBy: "\n")[3], "• Deck by Friday")
    }

    @MainActor
    func testListItemsFromTheModelSitOnConsecutiveLines() throws {
        let draft = "Hi Tomas,\n\nPlan below.\n\nBest,\nSam"
        let ops = [
            ParagraphOp(op: .insertAfter, id: "p2", text: "- Send the deck"),
            ParagraphOp(op: .insertAfter, id: "p2", text: "- Book the call"),
        ]
        let after = try ParagraphEdits.apply(ops, sent: draft, current: draft)
        XCTAssertTrue(after.contains("Plan below.\n\n- Send the deck\n- Book the call\n\nBest,"), after)
        let document = DocumentModel()
        document.userEdited(draft, at: .distantPast)
        _ = document.apply(ops: [DocumentOp(op: .replace, text: after, target: "whole_document")], expectedRevision: document.revision)
        XCTAssertTrue(document.text.contains("• Send the deck\n• Book the call"))
    }
}
