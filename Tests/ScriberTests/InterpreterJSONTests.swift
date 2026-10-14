import XCTest
@testable import ScriberCore

final class InterpreterJSONTests: XCTestCase {
    func testComposeWithEmptyOpsStaysEmptyForPlanner() throws {
        let raw = """
        {"intent":"compose","assistant_message":"Thanks for yesterday. The expansion point stuck with me.","ops":[]}
        """
        let parsed = try InterpreterJSON.parse(raw, forcedIntent: nil, utterance: "write a short thanks")
        XCTAssertEqual(parsed.intent, .compose)
        XCTAssertTrue(parsed.ops.isEmpty)
        XCTAssertEqual(parsed.assistantMessage, "Thanks for yesterday. The expansion point stuck with me.")
    }

    func testParsesSpans() throws {
        let raw = """
        {"intent":"edit","ops":[],"spans":[{"role":"meta","quote":"that's not ideal"},{"role":"payload","quote":"cheers Sam"}]}
        """
        let parsed = try InterpreterJSON.parse(raw, forcedIntent: nil, utterance: "that's not ideal cheers Sam")
        XCTAssertEqual(parsed.spans.map(\.role), [.meta, .payload])
        XCTAssertEqual(parsed.spans.last?.quote, "cheers Sam")
    }

    func testDictateFallsBackToUtterance() throws {
        let raw = #"{"intent":"dictate","assistant_message":null,"ops":[]}"#
        let parsed = try InterpreterJSON.parse(
            raw,
            forcedIntent: .dictate,
            utterance: "Write exactly: We raised two hundred thousand euros."
        )
        XCTAssertEqual(parsed.ops.first?.text, "We raised two hundred thousand euros.")
    }

    func testDiscussStripsOps() throws {
        let raw = #"{"intent":"discuss","assistant_message":"The opening is fine.","ops":[{"op":"append","text":"oops"}]}"#
        let parsed = try InterpreterJSON.parse(raw, forcedIntent: nil, utterance: "does this work?")
        XCTAssertEqual(parsed.intent, .discuss)
        XCTAssertTrue(parsed.ops.isEmpty)
        XCTAssertEqual(parsed.assistantMessage, "The opening is fine.")
    }

    func testExtractsFencedJSON() throws {
        let raw = """
        Sure.
        ```json
        {"intent":"compose","assistant_message":null,"ops":[{"op":"append","text":"Hello Tomas."}]}
        ```
        """
        let parsed = try InterpreterJSON.parse(raw, forcedIntent: nil, utterance: "write hello")
        XCTAssertEqual(parsed.ops.first?.text, "Hello Tomas.")
    }

    func testNoIsNotAnInterruptWhenIdle() {
        XCTAssertNil(InterruptLexicon.match("no", hasInFlight: false))
        XCTAssertEqual(InterruptLexicon.match("no", hasInFlight: true), .cancel)
        XCTAssertEqual(InterruptLexicon.match("stop", hasInFlight: false), .cancel)
    }

    func testUnknownIntentWithAppendBecomesCompose() throws {
        let raw = #"{"intent":"WRITE_EMAIL","assistant_message":null,"ops":[{"op":"append","text":"Dear Tomas,"}]}"#
        let parsed = try InterpreterJSON.parse(raw, forcedIntent: nil, utterance: "write Tomas")
        XCTAssertEqual(parsed.intent, .compose)
        XCTAssertEqual(parsed.ops.first?.text, "Dear Tomas,")
    }

    func testWriterAppendWithoutTextIsNotAnEdit() throws {
        let raw = #"{"action":"append","find":"","text":"","note":"Email draft created based on the request."}"#
        let parsed = try InterpreterJSON.parse(raw, forcedIntent: nil, utterance: "write an email to Lena")
        XCTAssertEqual(parsed.intent, .discuss)
        XCTAssertTrue(parsed.ops.isEmpty)
    }

    func testWriterActionsMapToOps() throws {
        let replace = try InterpreterJSON.parse(
            #"{"action":"replace","find":"Thanks.","text":"Thank you so much.","note":"Warmer."}"#,
            forcedIntent: nil, utterance: "make it warmer"
        )
        XCTAssertEqual(replace.intent, .edit)
        XCTAssertEqual(replace.ops, [DocumentOp(op: .replace, text: "Thank you so much.", anchor: "Thanks.")])
        XCTAssertEqual(replace.assistantMessage, "Warmer.")

        let rewrite = try InterpreterJSON.parse(
            #"{"action":"replace_all","find":"","text":"Hi Tomas,","note":"Rewrote."}"#,
            forcedIntent: nil, utterance: "start over"
        )
        XCTAssertEqual(rewrite.ops.first?.target, "whole_document")

        let none = try InterpreterJSON.parse(
            #"{"action":"none","find":"","text":"","note":"Nothing to change."}"#,
            forcedIntent: nil, utterance: "this looks great"
        )
        XCTAssertEqual(none.intent, .discuss)
        XCTAssertTrue(none.ops.isEmpty)
    }

    func testWriterNoteIsNeverPastedIntoDocument() throws {
        let spans = [
            SpeechSpan(role: .instruction, quote: "let's write an email to Lena"),
            SpeechSpan(role: .brief, quote: "thanking her for the intro")
        ]
        let utterance = "let's write an email to Lena thanking her for the intro"
        let plan = SpanPlanner.plan(spans: spans, utterance: utterance, document: "")
        let parsed = try InterpreterJSON.parse(
            #"{"action":"append","find":"","text":"","note":"Email draft created based on the request."}"#,
            forcedIntent: nil, utterance: utterance
        )
        let result = SpanPlanner.reconcile(response: parsed, spans: spans, utterance: utterance, document: "", plan: plan)
        XCTAssertFalse(result.response.ops.contains { $0.text?.contains("Email draft created") == true })
    }

    func testReplaceOnEmptyDocumentBecomesAppend() throws {
        let spans = [SpeechSpan(role: .instruction, quote: "write a note to Tomas")]
        let plan = SpanPlanner.plan(spans: spans, utterance: "write a note to Tomas", document: "")
        let parsed = try InterpreterJSON.parse(
            #"{"action":"replace_all","find":"","text":"Hi Tomas,\n\nTalk tomorrow.\n\nBest,\nSam","note":"Drafted."}"#,
            forcedIntent: nil, utterance: "write a note to Tomas"
        )
        let result = SpanPlanner.reconcile(response: parsed, spans: spans, utterance: "write a note to Tomas", document: "", plan: plan)
        XCTAssertEqual(result.response.ops.first?.op, .append)
    }

    func testWriteCueDoesNotForceCompose() {
        XCTAssertNil(
            EscapePhrases.forceIntent("okay let's write an email to Tomas", documentIsEmpty: true)
        )
        XCTAssertEqual(
            EscapePhrases.forceIntent("write exactly: hello", documentIsEmpty: true),
            .dictate
        )
        XCTAssertNil(
            EscapePhrases.forceIntent("does this transition work?", documentIsEmpty: true)
        )
    }
}
