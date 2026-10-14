import XCTest
@testable import ScriberCore

final class CommandTests: XCTestCase {
    private let email = "Hi Lena,\n\nThank you for connecting me with someone from Haven Founders. I'll be in touch with them soon.\n\nBest,\nSam"

    private func apply(_ resolution: CommandPlanner.Resolution, to doc: String) throws -> String {
        guard case .edit(let op, _) = resolution else {
            XCTFail("expected an edit, got \(resolution)")
            return doc
        }
        return try DocumentModel.apply(op: op, to: doc)
    }

    // MARK: Locating

    func testMisheardNameStillLocates() {
        let match = TextLocator.find("someone from heaven founders", in: email)
        XCTAssertEqual(match?.text, "someone from Haven Founders")
    }

    func testDroppedWordStillLocates() {
        let match = TextLocator.find("connecting with someone from Haven Founders", in: email)
        XCTAssertEqual(match?.text, "connecting me with someone from Haven Founders")
    }

    func testStructuralReferences() {
        XCTAssertEqual(TextLocator.find("the sign-off", in: email)?.text, "Best,\nSam")
        XCTAssertEqual(TextLocator.find("the second paragraph", in: email)?.text.hasPrefix("Thank you"), true)
        XCTAssertEqual(TextLocator.find("the part about being in touch", in: email)?.text, "I'll be in touch with them soon.")
    }

    func testUnrelatedTextIsNotFound() {
        XCTAssertNil(TextLocator.find("the pricing discussion we had in March", in: email))
        XCTAssertNil(TextLocator.find("it", in: email))
    }

    func testRespellsNamesFromTheDraft() {
        XCTAssertEqual(TextLocator.respellNames("with heaven founders", using: email), "with Haven Founders")
        XCTAssertEqual(TextLocator.respellNames("thanks Lina", using: email), "thanks Lena")
    }

    // MARK: Parsing

    func testParsesReplaceForms() {
        XCTAssertEqual(
            CommandParser.parse("Instead of saying someone from heaven founders, just say with heaven founders."),
            .replace(target: "someone from heaven founders", with: "with heaven founders")
        )
        XCTAssertEqual(
            CommandParser.parse("Okay, replace touch soon with talk next week"),
            .replace(target: "touch soon", with: "talk next week")
        )
        XCTAssertEqual(
            CommandParser.parse("Okay, I wouldn't say with someone from Haven Founders, you can just say with Haven Founders."),
            .replace(target: "with someone from Haven Founders", with: "with Haven Founders")
        )
    }

    func testParsesSessionMultiCommand() {
        let commands = CommandParser.parseAll("No, no, delete the last part you said. And in the email, you say connecting me with someone from Haven Founders. Just say connecting me with Haven Founders.")
        XCTAssertEqual(commands, [
            .delete(target: nil),
            .replace(target: "connecting me with someone from Haven Founders", with: "connecting me with Haven Founders")
        ])
    }

    func testParsesRewriteDeleteExact() {
        XCTAssertEqual(CommandParser.parse("make it a bit warmer"), .rewrite(target: "it", how: "a bit warmer"))
        XCTAssertEqual(CommandParser.parse("Make the second paragraph shorter."), .rewrite(target: "the second paragraph", how: "shorter"))
        XCTAssertEqual(CommandParser.parse("delete the part about being in touch"), .delete(target: "the part about being in touch"))
        XCTAssertEqual(
            CommandParser.parse("say exactly we close the round on March 15th before the sign off"),
            .exact(text: "we close the round on March 15th", position: .before("sign off"))
        )
    }

    func testOrdinarySpeechIsNotACommand() {
        XCTAssertNil(CommandParser.parseAll("Let's write an email to Lena thanking her for connecting me with someone from Haven Founders."))
        XCTAssertNil(CommandParser.parseAll("Make an email to Lena thanking her for the intro."))
        XCTAssertNil(CommandParser.parseAll("This type of person would never say that."))
        XCTAssertNil(CommandParser.parseAll("Delete the last part. And then add a paragraph about the sponsorship."))
    }

    // MARK: Resolving

    func testReplaceAbsorbsRestatedWordAndKeepsDraftSpelling() throws {
        let command = CommandParser.parse("Instead of saying someone from heaven founders, just say with heaven founders.")!
        let result = try apply(CommandPlanner.resolve(command, document: email, recent: []), to: email)
        XCTAssertTrue(result.contains("Thank you for connecting me with Haven Founders. I'll be in touch"), result)
    }

    func testReplaceNotFoundDoesNothing() {
        let resolution = CommandPlanner.resolve(.replace(target: "the pricing discussion we had", with: "x"), document: email, recent: [])
        guard case .notFound = resolution else { return XCTFail("\(resolution)") }
    }

    func testDeleteThatRemovesTheLastChange() throws {
        let doc = email + "\n\njust say with heaven founders."
        let result = try apply(CommandPlanner.resolve(.delete(target: nil), document: doc, recent: ["just say with heaven founders."]), to: doc)
        XCTAssertEqual(result, email)
    }

    func testDeletePhraseTakesItsSentence() throws {
        let result = try apply(CommandPlanner.resolve(.delete(target: "in touch with them soon"), document: email, recent: []), to: email)
        XCTAssertEqual(result, "Hi Lena,\n\nThank you for connecting me with someone from Haven Founders.\n\nBest,\nSam")
    }

    func testExactWordsGoAboveSignOff() throws {
        let result = try apply(CommandPlanner.resolve(.exact(text: "totally understandable that you can't sponsor right now", position: .end), document: email, recent: []), to: email)
        XCTAssertTrue(result.hasSuffix("Totally understandable that you can't sponsor right now.\n\nBest,\nSam"), result)
    }

    func testExactWordsAfterASentence() throws {
        let result = try apply(CommandPlanner.resolve(
            .exact(text: "it means a lot", position: .after("someone from heaven founders")),
            document: email, recent: []
        ), to: email)
        XCTAssertTrue(result.contains("Haven Founders. It means a lot. I'll be in touch"), result)
    }

    func testRewriteTargetsLocatedPassage() {
        let resolution = CommandPlanner.resolve(.rewrite(target: "the part about being in touch", how: "warmer"), document: email, recent: [])
        guard case .rewrite(let passage, let start, _) = resolution else { return XCTFail("\(resolution)") }
        XCTAssertEqual(passage, "I'll be in touch with them soon.")
        let op = CommandPlanner.rewriteOp(passage: passage, start: start, text: "I'll reach out to them this week.", in: email)
        XCTAssertNotNil(op)
    }

    // MARK: From the 13:34 session

    private let doubled = "Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nSam\n\nThank you for connecting me with Haven Founders.\n\nI will be in touch with them soon.\n\nSam\n\nI lead the second and the third program"

    func testParsesParagraphNumberDeletes() {
        XCTAssertEqual(CommandParser.parseAll("Delete the second, third and seventh paragraph."), [.deleteParagraphs([2, 3, 7])])
        XCTAssertEqual(CommandParser.parseAll("Delete these paragraphs. 2, 3 and 7."), [.deleteParagraphs([2, 3, 7])])
        XCTAssertEqual(CommandParser.parseAll("Delete that and also delete the second and the third paragraph."),
                       [.delete(target: nil), .deleteParagraphs([2, 3])])
        XCTAssertEqual(CommandParser.parseAll("Remove the last paragraph."), [.deleteParagraphs([-1])])
        XCTAssertEqual(CommandParser.parseAll("Delete the paragraph about pricing."), [.delete(target: "the paragraph about pricing")])
    }

    func testDeletesParagraphsByMarginNumber() throws {
        guard case .edits(let ops, _) = CommandPlanner.resolve(.deleteParagraphs([3, 4, 7]), document: doubled, recent: []) else {
            return XCTFail()
        }
        var doc = doubled
        for op in ops { doc = try DocumentModel.apply(op: op, to: doc) }
        XCTAssertEqual(doc, "Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nI will be in touch with them soon.\n\nSam")
    }

    func testMissingParagraphNumberIsReported() {
        guard case .notFound(let message) = CommandPlanner.resolve(.deleteParagraphs([12]), document: doubled, recent: []) else {
            return XCTFail()
        }
        XCTAssertTrue(message.contains("¶12"))
    }

    func testParsesInsertWithPlacement() {
        XCTAssertEqual(
            CommandParser.parseAll("Add a paragraph between the second and the third paragraph saying I will be in touch with them soon."),
            [.exact(text: "I will be in touch with them soon", position: .after("second paragraph"))]
        )
        XCTAssertEqual(
            CommandParser.parseAll("Add a sentence saying we meet after the launch."),
            [.exact(text: "we meet after the launch", position: .end)]
        )
        XCTAssertEqual(
            CommandParser.parseAll("After the greeting, add hope you had a good weekend."),
            [.exact(text: "hope you had a good weekend", position: .after("the greeting"))]
        )
        XCTAssertNil(CommandParser.parseAll("Add a paragraph about the sponsorship."))
    }

    func testInsertAfterParagraphNumber() throws {
        let doc = "Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nSam"
        let result = try apply(CommandPlanner.resolve(.exact(text: "I will be in touch with them soon", position: .after("second paragraph")), document: doc, recent: []), to: doc)
        XCTAssertEqual(result, "Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nI will be in touch with them soon.\n\nSam")
    }

    func testWholeEmailAppendKeepsOnlyWhatsNew() throws {
        let doc = "Hi Lena,\n\nHope you're doing well.\n\nSam"
        let op = try XCTUnwrap(CommandPlanner.mergeAppend("Hi Lena,\n\nThank you for connecting me with someone from Haven Founders.\n\nSam", into: doc))
        XCTAssertEqual(try DocumentModel.apply(op: op, to: doc),
                       "Hi Lena,\n\nHope you're doing well.\n\nThank you for connecting me with someone from Haven Founders.\n\nSam")
    }

    func testAppendOfExistingTextAddsNothing() {
        let doc = "Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nSam"
        XCTAssertNil(CommandPlanner.mergeAppend("Hi Lena,\n\nThank you for connecting me with Haven Founders.\n\nSam", into: doc))
    }

    // MARK: Cleanup safety

    func testDictatedSentenceIsNeverALeftover() {
        let request = ReviewRequest(utterance: "say thank you for connecting Haven Founders with me", spans: [
            SpeechSpan(role: .instruction, quote: "say"),
            SpeechSpan(role: .payload, quote: "thank you for connecting Haven Founders with me")
        ])
        XCTAssertFalse(DraftReview.isSpokenLeftover("Thank you for connecting Haven Founders with me.", requests: [request]))
    }

    func testInstructionLeftoverIsRecognized() {
        let request = ReviewRequest(utterance: "instead of saying someone from heaven founders, just say with heaven founders.", spans: [
            SpeechSpan(role: .meta, quote: "instead of saying someone from heaven founders,"),
            SpeechSpan(role: .instruction, quote: "just say with heaven founders.")
        ])
        XCTAssertTrue(DraftReview.isSpokenLeftover("just say with heaven founders.", requests: [request]))
    }
}
