import XCTest
@testable import ScriberCore

final class SpanPlannerTests: XCTestCase {
    func testInsteadOfSayBecomesReplaceWithoutModel() {
        let doc = "Dear Lena,\n\nThank you for connecting me with someone from Haven Founders. I appreciate your help."
        let utterance = "Instead of saying connecting with someone from Haven Founders, say connecting with Haven Founders."
        let spans = [
            SpeechSpan(role: .instruction, quote: "Instead of saying connecting with someone from Haven Founders, say connecting with Haven Founders."),
            SpeechSpan(role: .target, quote: "connecting with someone from Haven Founders"),
            SpeechSpan(role: .payload, quote: "connecting with Haven Founders")
        ]
        let plan = SpanPlanner.plan(spans: spans, utterance: utterance, document: doc)
        XCTAssertFalse(plan.needsModelProse)
        XCTAssertEqual(plan.intent, .edit)
        XCTAssertEqual(plan.ops.first?.op, .replace)
        XCTAssertEqual(plan.ops.first?.anchor, "connecting me with someone from Haven Founders")
        XCTAssertEqual(plan.ops.first?.text, "connecting with Haven Founders")
    }

    func testWouldntSayResolvesReplace() {
        let doc = "Thank you for connecting me with someone from Haven Founders."
        let spans = [
            SpeechSpan(role: .meta, quote: "Okay, I wouldn't say"),
            SpeechSpan(role: .target, quote: "with someone from Haven Founders"),
            SpeechSpan(role: .payload, quote: "with Haven Founders")
        ]
        let plan = SpanPlanner.plan(spans: spans, utterance: "Okay, I wouldn't say with someone from Haven Founders, you can just say with Haven Founders.", document: doc)
        XCTAssertFalse(plan.needsModelProse)
        XCTAssertEqual(plan.ops.first?.op, .replace)
        XCTAssertEqual(plan.ops.first?.text, "with Haven Founders")
    }

    func testOnlyMetaDoesNotEdit() {
        let plan = SpanPlanner.plan(
            spans: [SpeechSpan(role: .meta, quote: "Okay, well, this looks great.")],
            utterance: "Okay, well, this looks great.",
            document: "Hello"
        )
        XCTAssertFalse(plan.needsModelProse)
        XCTAssertEqual(plan.intent, .discuss)
        XCTAssertTrue(plan.ops.isEmpty)
    }

    func testMixedComplaintAndOrderStillNeedsWriter() {
        let plan = SpanPlanner.plan(
            spans: [
                SpeechSpan(role: .meta, quote: "That's not ideal, okay."),
                SpeechSpan(role: .instruction, quote: "this was an instruction, you should just write the email, not put in what I said")
            ],
            utterance: "That's not ideal, okay. You should just write the email, not put in what I said.",
            document: "Create an email to Lena saying thank you"
        )
        XCTAssertTrue(plan.needsModelProse)
        XCTAssertEqual(plan.intent, .edit)
    }

    func testCreateEmailNeedsProseAndReconcileStripsInstruction() {
        let utterance = "Create an email to Lena again saying thank you for connecting me with haven founders really appreciate it cheers Sam"
        let spans = [
            SpeechSpan(role: .instruction, quote: "Create an email to Lena again saying"),
            SpeechSpan(role: .payload, quote: "thank you for connecting me with haven founders really appreciate it cheers Sam")
        ]
        let plan = SpanPlanner.plan(spans: spans, utterance: utterance, document: "")
        XCTAssertTrue(plan.needsModelProse)
        XCTAssertEqual(plan.intent, .compose)

        let leaked = InterpreterResponse(
            intent: .compose,
            assistantMessage: utterance,
            ops: [DocumentOp(
                op: .append,
                text: "Create an email to Lena saying thank you for connecting me with Haven Founders. Really appreciate it. Cheers, Sam."
            )],
            spans: spans
        )
        let result = SpanPlanner.reconcile(
            response: leaked,
            spans: spans,
            utterance: utterance,
            document: "",
            plan: plan
        )
        XCTAssertTrue(result.copiedInstruction)
        XCTAssertEqual(result.response.ops.first?.op, .append)
        let text = result.response.ops.first?.text ?? ""
        XCTAssertFalse(text.lowercased().contains("create an email"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("cheers"))
    }

    func testFragileWithReplaceDroppedThenFallsBackToPayload() {
        let doc = "Thank you for connecting me with someone from Haven Founders."
        let spans = [
            SpeechSpan(role: .target, quote: "with someone from Haven Founders"),
            SpeechSpan(role: .payload, quote: "with Haven Founders")
        ]
        let plan = SpanPlanner.plan(spans: spans, utterance: "say with Haven Founders", document: doc)
        XCTAssertFalse(plan.needsModelProse)

        let bad = InterpreterResponse(
            intent: .edit,
            assistantMessage: nil,
            ops: [DocumentOp(op: .replace, text: "from", target: "with")],
            spans: spans
        )
        let result = SpanPlanner.reconcile(
            response: bad,
            spans: spans,
            utterance: "say with Haven Founders",
            document: doc,
            plan: plan
        )
        XCTAssertEqual(result.response.ops.first?.op, .replace)
        XCTAssertEqual(result.response.ops.first?.anchor, "with someone from Haven Founders")
        XCTAssertEqual(result.response.ops.first?.text, "with Haven Founders")
    }

    func testAlignerHighlightsPayloadOverInstruction() {
        let utterance = "Create an email saying thank you"
        let spans = [
            SpeechSpan(role: .instruction, quote: "Create an email saying"),
            SpeechSpan(role: .payload, quote: "thank you")
        ]
        let runs = SpanAligner.runs(utterance: utterance, spans: spans)
        XCTAssertEqual(runs.map(\.role), [.instruction, nil, .payload])
        XCTAssertEqual(runs.map(\.text).joined(), utterance)
    }
}
