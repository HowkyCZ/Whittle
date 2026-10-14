import XCTest
@testable import ScriberCore

final class ButtonPlaceTests: XCTestCase {
    // Claude's input as it reports itself: one 20 pt line in a full-screen window.
    let window = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let field = CGRect(x: 486, y: 45, width: 718, height: 20)

    func testComesBackWhereItWasDroppedWhenTheFieldReportsItselfDifferently() {
        let dropped = CGPoint(x: 436, y: 41.5)
        let place = ButtonPlace(dropped: dropped, size: 27, field: field, window: window)
        XCTAssertFalse(place.fromRight)
        XCTAssertFalse(place.fromTop)
        XCTAssertEqual(place.origin(field: field, window: window), dropped)
        // An image attached, or wrapped text: the field moves and grows, the spot beside the box doesn't.
        let moved = CGRect(x: 486, y: 95, width: 718, height: 60)
        XCTAssertEqual(place.origin(field: moved, window: window), dropped)
    }

    func testFollowsTheBoxWhenTheWindowMovesOrTheBoxRecentres() {
        let place = ButtonPlace(dropped: CGPoint(x: 1212, y: 40), size: 27, field: field, window: window)
        XCTAssertTrue(place.fromRight)
        let shiftedWindow = window.offsetBy(dx: 100, dy: 50)
        let shiftedField = field.offsetBy(dx: 100, dy: 50)
        XCTAssertEqual(place.origin(field: shiftedField, window: shiftedWindow), CGPoint(x: 1312, y: 90))
    }

    func testNearTheTopOfAWindowCountsFromTheTop() {
        let small = CGRect(x: 200, y: 200, width: 800, height: 600)
        let search = CGRect(x: 300, y: 740, width: 400, height: 24)
        let place = ButtonPlace(dropped: CGPoint(x: 710, y: 738), size: 27, field: search, window: small)
        XCTAssertTrue(place.fromTop)
        // The window grows downwards (its top stays): the button stays with the top.
        let taller = CGRect(x: 200, y: 100, width: 800, height: 700)
        XCTAssertEqual(place.origin(field: search, window: taller), CGPoint(x: 710, y: 738))
    }

    func testWithoutAWindowTheFieldIsTheReference() {
        let place = ButtonPlace(dropped: CGPoint(x: 1210, y: 50), size: 27, field: field, window: nil)
        XCTAssertEqual(place.origin(field: field, window: nil), CGPoint(x: 1210, y: 50))
    }
}
