import XCTest
@testable import ScriberCore

final class SpokenMechanicsTests: XCTestCase {
    let draft = """
    Hi Tomas,

    Thanks for yesterday. Your point about expansion stuck with me.

    We are raising [AMOUNT] to take the program beyond a single cohort. I think you are right that Rotterdam alone will not carry it.

    Would you be open to a short call next week?

    Best,
    Sam
    """

    private func applied(_ said: String, selection: NSRange? = nil, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let edit = SpokenMechanics.edit(in: said) else {
            XCTFail("no edit for “\(said)”", file: file, line: line)
            return nil
        }
        return SpokenMechanics.apply(edit, to: draft, selection: selection)
    }

    private func paragraphs(_ text: String?) -> [String] {
        DocumentParagraphs.split(text ?? "").map(\.text)
    }

    // MARK: Places

    func testPlacesAsPeopleSayThem() {
        let cases: [(String, DraftPlace)] = [
            ("paragraph two", .paragraph(2)), ("the second paragraph", .paragraph(2)), ("para 3", .paragraph(3)),
            ("paragraph number four", .paragraph(4)), ("the last paragraph", .paragraph(-1)), ("the 2nd paragraph", .paragraph(2)),
            ("the second sentence of paragraph three", .sentence(2, paragraph: 3)),
            ("sentence two in the third paragraph", .sentence(2, paragraph: 3)),
            ("the last sentence", .sentence(-1, paragraph: nil)), ("the second to last sentence", .sentence(-2, paragraph: nil)),
            ("the greeting", .greeting), ("the sign-off", .signOff), ("this", .selection), ("this paragraph", .currentParagraph),
            ("this sentence", .currentSentence), ("what I selected", .selection),
        ]
        for (said, expected) in cases {
            XCTAssertEqual(SpokenMechanics.place(said), expected, said)
        }
        XCTAssertNil(SpokenMechanics.place("the part about Rotterdam"))
    }

    func testPlacesInsideASentence() {
        let said = "In the second paragraph, after the first sentence, make it warmer"
        let found = SpokenMechanics.places(in: said).map(\.place)
        XCTAssertEqual(found, [.paragraph(2), .sentence(1, paragraph: nil)])
    }

    func testPointedRangeIsInTheDraft() throws {
        let pointed = try XCTUnwrap(SpokenMechanics.pointed(in: "Okay, paragraph three, make it warmer", draft: draft, selection: nil))
        XCTAssertEqual((draft as NSString).substring(with: pointed.range).prefix(14), "We are raising")
        let sentence = try XCTUnwrap(SpokenMechanics.range(of: .sentence(-1, paragraph: 3), in: draft, selection: nil))
        XCTAssertEqual((draft as NSString).substring(with: sentence), "I think you are right that Rotterdam alone will not carry it.")
    }

    // MARK: Edits that need no model

    func testMoveSwapAndEdges() {
        XCTAssertEqual(paragraphs(applied("Move paragraph four before paragraph two.")),
                       ["Hi Tomas,", "Would you be open to a short call next week?", "Thanks for yesterday. Your point about expansion stuck with me.",
                        "We are raising [AMOUNT] to take the program beyond a single cohort. I think you are right that Rotterdam alone will not carry it.",
                        "Best,", "Sam"])
        XCTAssertEqual(paragraphs(applied("okay, put paragraph two after paragraph three"))[1].prefix(9), "We are ra")
        XCTAssertEqual(paragraphs(applied("Swap paragraphs two and three"))[1].prefix(9), "We are ra")
        XCTAssertEqual(paragraphs(applied("Move paragraph four to the top"))[0], "Would you be open to a short call next week?")
        // The sign-off pair keeps its single line break when it isn't moved apart.
        XCTAssertTrue(applied("Move paragraph two to the end")?.contains("Best,\nSam") == true)
    }

    func testDeleteMergeSplit() {
        XCTAssertEqual(paragraphs(applied("Delete paragraph four")).count, 5)
        XCTAssertEqual(paragraphs(applied("Remove the last sentence of paragraph three"))[2],
                       "We are raising [AMOUNT] to take the program beyond a single cohort.")
        XCTAssertTrue(paragraphs(applied("Merge paragraphs two and three"))[1].hasSuffix("stuck with me. We are raising [AMOUNT] to take the program beyond a single cohort. I think you are right that Rotterdam alone will not carry it."))
        XCTAssertEqual(paragraphs(applied("Join paragraph two with the next one")).count, 5)
        let split = paragraphs(applied("Split paragraph three after the first sentence"))
        XCTAssertEqual(split[2], "We are raising [AMOUNT] to take the program beyond a single cohort.")
        XCTAssertEqual(split[3], "I think you are right that Rotterdam alone will not carry it.")
    }

    func testExactWording() {
        XCTAssertEqual(paragraphs(applied("Replace the second sentence of paragraph two with exactly: your point has stayed with me."))[1],
                       "Thanks for yesterday. Your point has stayed with me.")
        XCTAssertEqual(paragraphs(applied("After paragraph three, say exactly we would love your eyes on the plan."))[3],
                       "We would love your eyes on the plan.")
        XCTAssertEqual(paragraphs(applied("after the first sentence of paragraph three say exactly it's going well, end quote"))[2],
                       "We are raising [AMOUNT] to take the program beyond a single cohort. It's going well I think you are right that Rotterdam alone will not carry it.")
        XCTAssertEqual(paragraphs(applied("At the end add word for word P.S. Say hi to Ana.")).last, "P.S. Say hi to Ana.")
    }

    func testBoldAndList() {
        XCTAssertTrue(applied("Make the last sentence of paragraph three bold")?.contains("**I think you are right that Rotterdam alone will not carry it.**") == true)
        XCTAssertTrue(applied("bold single cohort")?.contains("**single cohort**") == true)
        XCTAssertEqual(paragraphs(applied("Make paragraph three a list")).dropFirst(2).prefix(2),
                       ["• We are raising [AMOUNT] to take the program beyond a single cohort.", "• I think you are right that Rotterdam alone will not carry it."])
    }

    func testSelectionAsTarget() {
        let selection = (draft as NSString).range(of: "a short call")
        XCTAssertTrue(applied("Replace this with exactly a quick chat", selection: selection)?.contains("open to a quick chat next week") == true)
    }

    // MARK: What stays with the editor model

    func testSemanticRequestsAreNotMechanical() {
        for said in ["Make paragraph two warmer", "Replace the second sentence with something friendlier",
                     "I think we should move paragraph two before the ask", "Make it into bullet points",
                     "After paragraph three say exactly we would love your eyes, end quote, and make it warmer",
                     "Delete the part about Rotterdam"] {
            XCTAssertNil(SpokenMechanics.edit(in: said), said)
        }
    }

    // MARK: Transcript colouring

    func testSpansForAnExactInsert() {
        let said = "Okay, after paragraph three, say exactly we would love your eyes on the plan"
        let spans = SpokenMechanics.spans(for: said)
        XCTAssertEqual(spans.map(\.role), [.meta, .instruction, .target, .instruction, .payload])
        XCTAssertEqual(spans.first { $0.role == .target }?.quote, "paragraph three")
        XCTAssertEqual(spans.last?.quote, "we would love your eyes on the plan")
        // Not a mechanical edit, but the place is still marked.
        XCTAssertEqual(SpokenMechanics.spans(for: "make the second paragraph warmer").map(\.quote), ["the second paragraph"])
    }
}
