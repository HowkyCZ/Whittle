import XCTest
@testable import ScriberCore

final class OutlineTests: XCTestCase {
    private let draft = """
    Hi Tomas,

    Thanks for yesterday. Your point about expansion stuck with me.

    Idea-to-Pilot takes founders from idea to demo in eight weeks.

    Would you be open to a short call?

    Best,
    Sam
    """

    private var outline: Outline {
        Outline(sections: [
            OutlineSection(id: "s1", title: "Opening", points: [OutlinePoint(id: "s1.1", text: "Thank him", covered: true)], paragraphs: [1]),
            OutlineSection(id: "s2", title: "Who we are", points: [OutlinePoint(id: "s2.1", text: "What Idea-to-Pilot is", covered: true),
                                                                   OutlinePoint(id: "s2.2", text: "Frame it as Benelux")], paragraphs: [2]),
            OutlineSection(id: "s3", title: "The raise", points: [OutlinePoint(id: "s3.1", text: "Current amount")]),
            OutlineSection(id: "s4", title: "The ask", points: [OutlinePoint(id: "s4.1", text: "Short call", covered: true)], paragraphs: [3]),
        ], checkedDraft: draft)
    }

    func testPointStatus() {
        let o = outline
        XCTAssertEqual(o.status(of: o.sections[1].points[0], in: o.sections[1]), .covered)
        XCTAssertEqual(o.status(of: o.sections[1].points[1], in: o.sections[1]), .missing)
        XCTAssertEqual(o.status(of: o.sections[2].points[0], in: o.sections[2]), .notWritten)
        XCTAssertEqual(o.writtenCount, 3)
    }

    func testMergingKeepsIDsAndNumbersNewOnes() {
        let reply = OutlineReply(sections: [
            .init(id: "s1", title: "Opening", points: [.init(id: "s1.1", text: "Thank him", covered: true)], paragraphs: ["p2"]),
            .init(id: "s2", title: "Who we are", points: [.init(id: "s2.1", text: "What Idea-to-Pilot is", covered: true)], paragraphs: ["p3"]),
            .init(id: "new", title: "Why now", points: [.init(id: "new", text: "Before the next cohort")]),
            .init(id: "s4", title: "The ask", paragraphs: ["p4", "p3", "p99"]),
        ], write: ["new"])
        let (merged, added, write) = outline.merging(reply, draft: draft)
        XCTAssertEqual(merged.sections.map(\.id), ["s1", "s2", "s5", "s4"])
        XCTAssertEqual(added, ["s5"])
        XCTAssertEqual(write, ["s5"])
        XCTAssertEqual(merged.sections[2].points.map(\.id), ["s5.1"])
        // p3 already belongs to "Who we are"; p99 doesn't exist.
        XCTAssertEqual(merged.sections[3].paragraphs, [3])
        XCTAssertTrue(merged.isCurrent(for: draft))
    }

    func testUnwrittenSectionsCoverNothing() {
        let reply = OutlineReply(sections: [.init(id: "s3", title: "The raise", points: [.init(id: "s3.1", text: "Amount", covered: true)])])
        let (merged, _, _) = outline.merging(reply, draft: draft)
        XCTAssertFalse(merged.sections[0].points[0].covered)
    }

    func testRegroupMovesTextWithItsSection() throws {
        var sections = outline.sections
        sections.swapAt(0, 3)  // The ask first, the opening last
        let (text, moved) = try XCTUnwrap(Outline.regroup(draft, sections: sections))
        XCTAssertEqual(text, """
        Hi Tomas,

        Would you be open to a short call?

        Idea-to-Pilot takes founders from idea to demo in eight weeks.

        Thanks for yesterday. Your point about expansion stuck with me.

        Best,
        Sam
        """)
        XCTAssertEqual(moved.first { $0.id == "s4" }?.paragraphs, [1])
        XCTAssertEqual(moved.first { $0.id == "s1" }?.paragraphs, [3])
    }

    func testRegroupLeavesMatchingOrderAlone() {
        XCTAssertNil(Outline.regroup(draft, sections: outline.sections))
    }

    func testWriteRequestSaysWhereEachSectionGoes() throws {
        let request = try XCTUnwrap(outline.writeRequest(for: ["s3"], draft: draft))
        XCTAssertTrue(request.contains("“The raise”, after p3 (the end of “Who we are”)"), request)
        XCTAssertTrue(request.contains("Must say: Current amount."), request)
    }
}

final class ReviewTextTests: XCTestCase {
    private let draft = "We are currently raising [RAISE AMOUNT] to take Idea-to-Pilot beyond a single cohort.\n\nWould you be open to a short call?"

    func testLocatesLooseQuotes() throws {
        let ns = draft as NSString
        XCTAssertEqual(ns.substring(with: try XCTUnwrap(ReviewText.locate("beyond a single cohort", in: draft))), "beyond a single cohort")
        XCTAssertEqual(ns.substring(with: try XCTUnwrap(ReviewText.locate("“Beyond a single cohort.”", in: draft))), "beyond a single cohort")
        XCTAssertEqual(ns.substring(with: try XCTUnwrap(ReviewText.locate("to take  Idea-to-Pilot\nbeyond", in: draft))), "to take Idea-to-Pilot beyond")
        XCTAssertNil(ReviewText.locate("a sentence that isn't there", in: draft))
    }

    func testEditorRequestHasApprovedAndConcludedOnly() throws {
        let range = (draft as NSString).range(of: "beyond a single cohort")
        let call = (draft as NSString).range(of: "Would you be open to a short call?")
        let comments = [
            ReviewComment(agentID: "skeptic", quote: "beyond a single cohort", range: range, message: "Into what?",
                          state: .concluded, conclusion: "Say it's a second city, named once confirmed."),
            ReviewComment(agentID: "reader", quote: "short call", range: call, message: "Offer two time slots.", state: .approved),
            ReviewComment(agentID: "cutter", quote: "currently", range: NSRange(location: 7, length: 9), message: "Cut “currently”."),
        ]
        let request = try XCTUnwrap(ReviewText.editorRequest(comments, agents: ReviewAgent.defaults, draft: draft))
        XCTAssertTrue(request.contains("On “beyond a single cohort”: Say it's a second city, named once confirmed. (agreed with Skeptic)"), request)
        XCTAssertTrue(request.contains("Offer two time slots. (Reader)"), request)
        XCTAssertFalse(request.contains("currently"), request)
        XCTAssertNil(ReviewText.editorRequest([comments[2]], agents: ReviewAgent.defaults, draft: draft))
    }
}

final class ContextTextTests: XCTestCase {
    func testTemplateCommentsAreNotSent() {
        XCTAssertEqual(ContextText.clean("<!--\nAbout you.\n- Name: Alex\n-->\n"), "")
        XCTAssertEqual(ContextText.clean("<!-- tip -->\n- Name: Sam\n<!-- another -->\n- Role: designer"), "- Name: Sam\n\n- Role: designer")
    }
}

final class AppSupportTests: XCTestCase {
    func testScriberFolderMovesIntoWhittles() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("appsupport-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let old = base.appendingPathComponent("Scriber")
        try fm.createDirectory(at: old.appendingPathComponent("models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: old.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: old.appendingPathComponent("models/ggml.bin"))
        try Data("old".utf8).write(to: old.appendingPathComponent("logs/timing.log"))
        try Data("clip".utf8).write(to: old.appendingPathComponent("logs/turns.jsonl"))
        // Whittle already wrote a log before the move.
        let new = base.appendingPathComponent("Whittle")
        try fm.createDirectory(at: new.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: new.appendingPathComponent("logs/timing.log"))

        let moved = AppSupport.moveFromPreviousName(base: base)

        XCTAssertEqual(moved, ["logs/timing.log", "logs/turns.jsonl", "models"])
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("models/ggml.bin"), encoding: .utf8), "weights")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("logs/timing.log"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("logs/timing (Scriber).log"), encoding: .utf8), "old")
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(AppSupport.moveFromPreviousName(base: base), [])
    }
}

final class EditRoutingTests: XCTestCase {
    func testEverydayEditsAreFast() {
        XCTAssertFalse(EditRouting.needsThorough("In the second paragraph, after the fundraising line, say exactly we would love your eyes on the plan."))
        XCTAssertFalse(EditRouting.needsThorough("Make it warmer."))
        XCTAssertFalse(EditRouting.needsThorough("Write an email to Lena thanking her for the intro."))
    }

    func testWholeDraftWorkIsThorough() {
        XCTAssertTrue(EditRouting.needsThorough("Okay, but if it's notes, maybe it should be bullet points."))
        XCTAssertTrue(EditRouting.needsThorough("Restructure the whole thing so the ask comes first."))
        XCTAssertTrue(EditRouting.needsThorough("Summarize this into three lines."))
        XCTAssertTrue(EditRouting.needsThorough(Array(repeating: "word", count: 80).joined(separator: " ")))
    }
}
