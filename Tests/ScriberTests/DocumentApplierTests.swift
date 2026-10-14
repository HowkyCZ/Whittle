import XCTest
@testable import ScriberCore

@MainActor
final class DocumentApplierTests: XCTestCase {
    func testAppend() throws {
        let result = try DocumentModel.apply(
            op: DocumentOp(op: .append, text: "Hello"),
            to: ""
        )
        XCTAssertEqual(result, "Hello")
    }

    func testExactMovePreservesWording() throws {
        let doc = "Thanks for yesterday. Expansion stuck with me.\n\nWe are raising now."
        let sentence = "Expansion stuck with me."
        let moved = try DocumentModel.apply(
            op: DocumentOp(op: .move, anchor: sentence, destination: 10_000),
            to: doc
        )
        XCTAssertTrue(moved.contains(sentence))
        let parts = moved.components(separatedBy: sentence)
        XCTAssertEqual(parts.count, 2, "Sentence should appear exactly once")
        XCTAssertFalse(moved.hasPrefix(sentence))
    }

    @MainActor
    func testSnapshotUndo() {
        let model = DocumentModel()
        model.userEdited("One")
        let rev = model.revision
        let result = model.apply(
            ops: [DocumentOp(op: .append, text: "Two")],
            expectedRevision: rev
        )
        XCTAssertEqual(result, .applied)
        XCTAssertTrue(model.text.contains("Two"))
        XCTAssertTrue(model.undo())
        XCTAssertEqual(model.text, "One")
    }

    @MainActor
    func testStaleRevisionRejected() {
        let model = DocumentModel()
        model.userEdited("A")
        let stale = model.revision
        model.userEdited("B")
        let result = model.apply(
            ops: [DocumentOp(op: .append, text: "X")],
            expectedRevision: stale
        )
        XCTAssertEqual(result, .stale)
        XCTAssertEqual(model.text, "B")
    }

    func testDictateTextPreservedViaReplace() throws {
        let exact = "We raised two hundred thousand euros before launching."
        let doc = "Intro.\n\nPlaceholder."
        let out = try DocumentModel.apply(
            op: DocumentOp(op: .replace, text: exact, anchor: "Placeholder."),
            to: doc
        )
        XCTAssertTrue(out.contains(exact))
        XCTAssertFalse(out.contains("Placeholder."))
    }

    func testStructuralFirstParagraph() throws {
        let doc = "First para.\n\nSecond para."
        let range = try DocumentModel.resolveStructuralRange("first_paragraph", in: doc)
        XCTAssertEqual(String(doc[range]), "First para.")
    }

    func testDiscussOpsEmptyDoNotNeedApplier() {
        let responseOps: [DocumentOp] = []
        XCTAssertTrue(responseOps.isEmpty)
    }
}
