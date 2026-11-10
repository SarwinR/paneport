import CoreGraphics
import XCTest
@testable import Paneport

final class DisplayLayoutTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let size = CGSize(width: 1920, height: 1080)

    func testSnapsToTheNearestEdge() {
        let origin = DisplayLayout.snappedOrigin(size: size, proposed: CGPoint(x: 2000, y: 300), others: [main])
        XCTAssertEqual(origin, CGPoint(x: 1920, y: 300))
    }

    func testAlignsEdgesThatAreClose() {
        let origin = DisplayLayout.snappedOrigin(size: size, proposed: CGPoint(x: 2000, y: 30), others: [main])
        XCTAssertEqual(origin, CGPoint(x: 1920, y: 0))
    }

    func testMovesOutOfAnOverlap() {
        let origin = DisplayLayout.snappedOrigin(size: size, proposed: CGPoint(x: 100, y: 100), others: [main])
        XCTAssertEqual(origin, CGPoint(x: 100, y: 1080))
        XCTAssertFalse(CGRect(origin: origin, size: size).intersects(main.insetBy(dx: 1, dy: 1)))
    }

    func testKeepsAMinimumSharedEdge() {
        // Proposed far below and to the right: it lands below the main display, overlapping
        // its bottom edge by just the minimum so the two still count as neighbours.
        let origin = DisplayLayout.snappedOrigin(size: size, proposed: CGPoint(x: 1920, y: 5000), others: [main])
        XCTAssertEqual(origin, CGPoint(x: 1920 - DisplayLayout.minimumSharedEdge, y: 1080))
    }

    func testReturnsTheProposalWhenAlone() {
        let proposed = CGPoint(x: 123, y: 456)
        XCTAssertEqual(DisplayLayout.snappedOrigin(size: size, proposed: proposed, others: []), proposed)
    }
}
