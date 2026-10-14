import XCTest
@testable import ScriberCore

final class UtterancePolicyTests: XCTestCase {
    func testMetaCommentaryIsNotHardGated() {
        XCTAssertEqual(
            UtterancePolicy.decide("Okay, well, this looks great.", document: "Hello"),
            .proceed
        )
        XCTAssertEqual(
            UtterancePolicy.decide("Instead you just wrote that again.", document: "Hello"),
            .proceed
        )
        XCTAssertEqual(
            UtterancePolicy.decide("Go to the first paragraph.", document: "Hello"),
            .proceed
        )
        XCTAssertEqual(
            UtterancePolicy.decide("Hello.", document: ""),
            .proceed
        )
    }

    func testClearAndUndoStillLocal() {
        XCTAssertEqual(UtterancePolicy.decide("Okay so delete everything now.", document: "Hello"), .clear)
        XCTAssertEqual(UtterancePolicy.decide("undo that", document: "Hello"), .undo)
        XCTAssertEqual(UtterancePolicy.decide("   ", document: ""), .ignore("empty"))
    }

    func testDuplicateAppendRefused() {
        let doc = "Thanks for yesterday.\n\nWe're raising €200,000."
        XCTAssertTrue(OpSanitizer.isDuplicateAppend("Thanks for yesterday.", document: doc))
        XCTAssertTrue(OpSanitizer.isDuplicateAppend(doc, document: doc))
    }

}
