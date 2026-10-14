import XCTest
@testable import ScriberCore

final class DraftReviewTests: XCTestCase {
    private let messy = """
    Hi Lena,

    Hi Lena,

    Thank you for connecting me with Haven Founders.

    Best,
    Sam

    just say with heaven founders.
    """

    private let clean = "Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nBest,\nSam"

    private func request(_ utterance: String, _ spans: [SpeechSpan]) -> ReviewRequest {
        ReviewRequest(utterance: utterance, spans: spans)
    }

    func testLintFindsRepeatedGreetingAndTextAfterSignOff() {
        let report = DocumentLint.check(messy)
        XCTAssertTrue(report.hints.contains { $0.contains("greeting appears 2") })
        XCTAssertTrue(report.hints.contains { $0.contains("after the sign-off") })
        XCTAssertEqual(report.fixes.map(\.find), ["Hi Lena,\n\nHi Lena,"])
    }

    func testCleanEmailHasNoHints() {
        XCTAssertEqual(DocumentLint.check(clean).hints, [])
        XCTAssertNil(DraftReview.moveAboveSignOff(clean))
    }

    func testRepeatedGreetingAfterContentIsRemoved() throws {
        let doc = "Hi Lena,\n\nThank you for connecting me.\n\nHi Lena,\n\nBest,\nSam"
        let fixes = DocumentLint.check(doc).fixes
        let planned = DraftReview.ops(for: fixes, document: doc, requests: [])
        XCTAssertEqual(planned.result, "Hi Lena,\n\nThank you for connecting me.\n\nBest,\nSam")
    }

    func testStrayInstructionIsRemovedOnlyWhenItWasSpoken() {
        let spoken = request("instead of saying someone from heaven founders, just say with heaven founders.", [
            SpeechSpan(role: .meta, quote: "instead of saying someone from heaven founders,"),
            SpeechSpan(role: .instruction, quote: "just say with heaven founders.")
        ])
        let leftover = ParagraphVerdict(kind: .leftover, clean: "")
        XCTAssertNotNil(DraftReview.fix(for: "just say with heaven founders.", verdict: leftover, requests: [spoken]))
        XCTAssertNil(DraftReview.fix(for: "We should meet next week.", verdict: leftover, requests: [spoken]))
    }

    func testFullCleanupOfSessionDraft() {
        let spoken = request("instead of saying someone from heaven founders, just say with heaven founders.", [
            SpeechSpan(role: .meta, quote: "instead of saying someone from heaven founders,"),
            SpeechSpan(role: .instruction, quote: "just say with heaven founders.")
        ])
        var fixes = DocumentLint.check(messy).fixes
        fixes.append(DraftReview.fix(
            for: "just say with heaven founders.",
            verdict: ParagraphVerdict(kind: .leftover, clean: ""),
            requests: [spoken]
        )!)
        let planned = DraftReview.ops(for: fixes, document: messy, requests: [spoken])
        XCTAssertEqual(planned.rejected, [])
        XCTAssertEqual(planned.result, clean)
    }

    func testPolishMayDropFillerButNotRewrite() {
        let spoken = "Maybe like we will, you know, reach out if we come across any other ways how you could support."
        XCTAssertTrue(DraftReview.acceptsPolish(
            original: spoken,
            clean: "Maybe we will reach out if we come across any other ways you could support."
        ))
        XCTAssertFalse(DraftReview.acceptsPolish(
            original: spoken,
            clean: "We'd love to explore a partnership with your team next quarter."
        ))
    }

    func testContentAfterSignOffMovesAbove() {
        let doc = "Hi Lena,\n\nThanks.\n\nBest,\nSam\n\nP.S. totally understandable that you can't sponsor."
        let fix = DraftReview.moveAboveSignOff(doc)
        let planned = DraftReview.ops(for: [fix!], document: doc, requests: [])
        XCTAssertEqual(planned.result, "Hi Lena,\n\nThanks.\n\nP.S. totally understandable that you can't sponsor.\n\nBest,\nSam")
    }

    func testUnmetReplacementIsApplied() {
        let doc = "Hi Lena,\n\nThank you for connecting me with someone from Haven Founders.\n\nBest,\nSam"
        let req = request("instead of saying someone from Haven Founders just say with Haven Founders", [
            SpeechSpan(role: .target, quote: "someone from Haven Founders"),
            SpeechSpan(role: .payload, quote: "Haven Founders")
        ])
        XCTAssertTrue(DraftReview.unmetReplacements(document: doc, requests: [req]).isEmpty, "payload contains target's tail; ambiguous")

        let req2 = request("instead of saying connecting me with someone from Haven Founders say introducing me to Haven Founders", [
            SpeechSpan(role: .target, quote: "connecting me with someone from Haven Founders"),
            SpeechSpan(role: .payload, quote: "introducing me to Haven Founders")
        ])
        let fixes = DraftReview.unmetReplacements(document: doc, requests: [req2])
        XCTAssertEqual(fixes.first?.replace, "introducing me to Haven Founders")

        let undo = request("actually keep connecting me with someone from Haven Founders", [
            SpeechSpan(role: .payload, quote: "connecting me with someone from Haven Founders")
        ])
        XCTAssertTrue(DraftReview.unmetReplacements(document: doc, requests: [req2, undo]).isEmpty)
    }

    func testLatestMissingWords() {
        let req = request("then add a paragraph saying we close the round in March", [
            SpeechSpan(role: .instruction, quote: "then add a paragraph saying"),
            SpeechSpan(role: .payload, quote: "we close the round in March")
        ])
        XCTAssertNotNil(DraftReview.latestMissingWords(document: clean, requests: [req]))
        XCTAssertNil(DraftReview.latestMissingWords(document: clean + "\n\nWe close the round in March.", requests: [req]))
    }

    func testFixThatCopiesAnInstructionIsRejected() {
        let req = request("make the opening warmer and more personal please", [
            SpeechSpan(role: .instruction, quote: "make the opening warmer and more personal please")
        ])
        let planned = DraftReview.ops(
            for: [ReviewFix(find: "Hi Lena,", replace: "Make the opening warmer and more personal please")],
            document: messy, requests: [req]
        )
        XCTAssertTrue(planned.ops.isEmpty)
        XCTAssertEqual(planned.rejected.count, 1)
    }

    func testFixesThatRewriteTheDraftAreRejected() {
        let planned = DraftReview.ops(
            for: [ReviewFix(find: clean, replace: String(repeating: "Something else entirely. ", count: 20))],
            document: clean, requests: []
        )
        XCTAssertTrue(planned.ops.isEmpty)
        XCTAssertTrue(planned.rejected.last?.contains("rewrite") == true)
    }

    func testRecentKeepsTheLatestRequestsInWindow() {
        let now = Date()
        let old = ReviewRequest(utterance: "old", spans: [], at: now.addingTimeInterval(-600))
        let fresh = (0..<8).map { ReviewRequest(utterance: "r\($0)", spans: [], at: now) }
        XCTAssertEqual(DraftReview.recent([old] + fresh, now: now).map(\.utterance), ["r2", "r3", "r4", "r5", "r6", "r7"])
    }

    // From the session: the writer sent the whole email as a replacement for one sentence.
    func testWholeEmailReplacingOneSentenceBecomesFullRewrite() {
        let doc = "Hi Lena,\n\nThank you for connecting me with someone from Haven Founders. I'll be in touch with them soon.\n\nBest,\nSam\n\njust say with heaven founders."
        let op = DocumentOp(
            op: .replace,
            text: "Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nBest,\nSam",
            anchor: "I'll be in touch with them soon."
        )
        let fixed = SpanPlanner.normalizeAnchor(op, document: doc)
        XCTAssertEqual(fixed.target, "whole_document")
        XCTAssertNil(fixed.anchor)
    }

    func testSentenceReplaceInFirstParagraphStaysLocal() {
        let doc = "Thanks for the intro. I'll call them.\n\nBest,\nSam"
        let op = DocumentOp(op: .replace, text: "Thanks for the intro. I'll call them tomorrow.", anchor: "I'll call them.")
        let fixed = SpanPlanner.normalizeAnchor(op, document: doc)
        XCTAssertEqual(fixed.anchor, "I'll call them.")
        XCTAssertNil(fixed.target)
    }

    func testAsideWithWordsGoesToWriterNotStraightAppend() {
        let doc = "Thank you for connecting me with someone from Haven Founders."
        let spans = [
            SpeechSpan(role: .meta, quote: "instead of saying someone from heaven founders,"),
            SpeechSpan(role: .payload, quote: "with heaven founders.")
        ]
        let plan = SpanPlanner.plan(spans: spans, utterance: "instead of saying someone from heaven founders, just say with heaven founders.", document: doc)
        XCTAssertTrue(plan.needsModelProse)
    }
}
