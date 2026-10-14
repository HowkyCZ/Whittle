import XCTest
@testable import ScriberCore

final class ClauseChunkerTests: XCTestCase {
    func testOffByOneLabelsRealignByFocus() {
        let u = "And in the email, you say connecting me with someone from Haven Founders. Just say connecting me with Haven Founders."
        let clauses = ClauseChunker.clauses(u)
        XCTAssertEqual(clauses.count, 4)
        let labels = [
            ClauseLabel(index: 1, role: .target, focus: "connecting me with someone from Haven Founders"),
            ClauseLabel(index: 2, role: .target, focus: "connecting me with someone from Haven Founders"),
            ClauseLabel(index: 3, role: .payload, focus: "connecting me with Haven Founders")
        ]
        let spans = SpanBuilder.spans(utterance: u, clauses: clauses, labels: labels)
        XCTAssertEqual(spans.filter { $0.role == .target }.map(\.quote).last, "connecting me with someone from Haven Founders")
        XCTAssertEqual(spans.filter { $0.role == .payload }.map(\.quote), ["connecting me with Haven Founders"])
    }

    func testHedgedGistAfterJustSayPeelsTheFrame() {
        let u = "And just say maybe like we will, you know, reach out."
        let clauses = ClauseChunker.clauses(u)
        let labels = clauses.indices.map { i in
            ClauseLabel(index: i + 1, role: clauses[i].text == "And" ? .instruction : .brief)
        }
        let spans = SpanBuilder.spans(utterance: u, clauses: clauses, labels: labels)
        XCTAssertEqual(spans.first(where: { $0.role == .brief })?.quote.hasPrefix("maybe like"), true)
    }

    func testSplitsMixedUtteranceIntoClauses() {
        let u = "Okay, I wouldn't say with someone from Haven Founders, you can just say with Haven Founders."
        let texts = ClauseChunker.clauses(u).map(\.text)
        XCTAssertEqual(texts, [
            "Okay,",
            "I wouldn't",
            "say with someone from Haven Founders,",
            "you can just say with Haven Founders."
        ])
    }

    func testClauseRangesPointIntoUtterance() {
        let u = "Create an email to Lena saying thank you, cheers Sam."
        let ns = u as NSString
        for clause in ClauseChunker.clauses(u) {
            XCTAssertEqual(ns.substring(with: NSRange(location: clause.location, length: clause.length)), clause.text)
        }
    }

    func testInsteadOfSayingStaysOneFrame() {
        let texts = ClauseChunker.clauses("Instead of saying connecting with someone, say connecting with Haven Founders.").map(\.text)
        XCTAssertEqual(texts.first, "Instead of saying connecting with someone,")
        XCTAssertEqual(texts.last, "say connecting with Haven Founders.")
    }

    func testNumbersWithCommasAreNotSplit() {
        let texts = ClauseChunker.clauses("We raised 200,000 euros.").map(\.text)
        XCTAssertEqual(texts, ["We raised 200,000 euros."])
    }

    func testFocusNarrowsWordsAndFrameReadsAsAsk() {
        let u = "Okay, you can just say with Haven Founders."
        let clauses = ClauseChunker.clauses(u)
        let spans = SpanBuilder.spans(utterance: u, clauses: clauses, labels: [
            ClauseLabel(index: 1, role: .meta),
            ClauseLabel(index: 2, role: .payload, focus: "with Haven Founders")
        ])
        XCTAssertEqual(spans.map(\.role), [.meta, .instruction, .payload])
        XCTAssertEqual(spans.last?.quote, "with Haven Founders")
    }

    func testAdjacentWordsMergeIntoOnePayload() {
        let u = "Create an email to Lena saying thank you, really appreciate it, cheers Sam."
        let clauses = ClauseChunker.clauses(u)
        XCTAssertEqual(clauses.count, 4)
        let spans = SpanBuilder.spans(utterance: u, clauses: clauses, labels: [
            ClauseLabel(index: 1, role: .instruction),
            ClauseLabel(index: 2, role: .payload, focus: "thank you"),
            ClauseLabel(index: 3, role: .payload),
            ClauseLabel(index: 4, role: .payload)
        ])
        XCTAssertEqual(spans.map(\.role), [.instruction, .payload])
        XCTAssertEqual(spans.last?.quote, "thank you, really appreciate it, cheers Sam.")

        let plan = SpanPlanner.plan(spans: spans, utterance: u, document: "")
        XCTAssertTrue(plan.needsModelProse)
        XCTAssertEqual(plan.intent, .compose)
    }

    func testFramingVerbPeeledOffWordsWithoutFocus() {
        let u = "Create an email to Lena saying thank you for connecting me, cheers Sam"
        let clauses = ClauseChunker.clauses(u)
        let spans = SpanBuilder.spans(utterance: u, clauses: clauses, labels: [
            ClauseLabel(index: 1, role: .instruction),
            ClauseLabel(index: 2, role: .payload, focus: "saying thank you for connecting me,"),
            ClauseLabel(index: 3, role: .payload)
        ])
        XCTAssertEqual(spans.map(\.role), [.instruction, .payload])
        XCTAssertEqual(spans.first?.quote, "Create an email to Lena saying")
        XCTAssertEqual(spans.last?.quote, "thank you for connecting me, cheers Sam")
    }

    func testUnlabeledClausesDefaultToAsk() {
        let u = "Delete that."
        let spans = SpanBuilder.spans(utterance: u, clauses: ClauseChunker.clauses(u), labels: [])
        XCTAssertEqual(spans.map(\.role), [.instruction])
        let plan = SpanPlanner.plan(spans: spans, utterance: u, document: "Write a thank you email to Nemo.")
        XCTAssertTrue(plan.needsModelProse)
        XCTAssertEqual(plan.intent, .edit)
    }

    func testTrailingOffIsUnfinished() {
        XCTAssertTrue(Completeness.looksUnfinished("Okay, so let's write an email thanking her for connecting me with someone from"))
        XCTAssertTrue(Completeness.looksUnfinished("Let's write an email saying thank you to Lena for connecting me with"))
        XCTAssertFalse(Completeness.looksUnfinished("Haven Founders."))
        XCTAssertFalse(Completeness.looksUnfinished("Write a thank you email to Lena."))
    }

    func testParsesClauseLabelsWithFriendlyRoles() {
        let raw = #"{"complete":false,"labels":[{"i":1,"role":"ask"},{"i":2,"role":"words","focus":"cheers"},{"i":9,"role":"aside"}]}"#
        let parsed = InterpreterJSON.parseClauseLabels(raw, clauseCount: 2)
        XCTAssertEqual(parsed.complete, false)
        XCTAssertEqual(parsed.labels, [
            ClauseLabel(index: 1, role: .instruction),
            ClauseLabel(index: 2, role: .payload, focus: "cheers")
        ])
    }
}
