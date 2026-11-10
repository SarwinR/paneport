import CoreGraphics
import XCTest
@testable import Paneport

final class PointerMathTests: XCTestCase {
    func testPositionOnAStandardDisplay() {
        let bounds = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let placement = PointerMath.streamPosition(of: CGPoint(x: 2000, y: 100), displayBounds: bounds, streamWidth: 1920)
        XCTAssertEqual(placement.position, CGPoint(x: 80, y: 100))
        XCTAssertTrue(placement.isInside)
    }

    func testPositionOnAHiDPIDisplayIsDoubled() {
        let bounds = CGRect(x: 1920, y: 0, width: 1920, height: 1080)   // looks like 1920 wide, 3840 pixels
        let placement = PointerMath.streamPosition(of: CGPoint(x: 2000, y: 100), displayBounds: bounds, streamWidth: 3840)
        XCTAssertEqual(placement.position, CGPoint(x: 160, y: 200))
    }

    func testPointerOnAnotherDisplayIsOutside() {
        let bounds = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(PointerMath.streamPosition(of: CGPoint(x: 10, y: 10), displayBounds: bounds, streamWidth: 1920).isInside)
    }

    func testHiddenOnlyWhenTypingIsMoreRecentThanMovement() {
        XCTAssertTrue(PointerMath.isHiddenByTyping(secondsSinceKeyDown: 0.2, secondsSinceMouseMoved: 3))
        XCTAssertFalse(PointerMath.isHiddenByTyping(secondsSinceKeyDown: 3, secondsSinceMouseMoved: 0.2))
    }
}
