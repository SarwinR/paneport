import XCTest
@testable import Paneport

final class AnnexBTests: XCTestCase {
    func testReplacesLengthPrefixesWithStartCodes() {
        let avcc: [UInt8] = [0, 0, 0, 2, 0x65, 0x88, 0, 0, 0, 1, 0x41]
        XCTAssertEqual(AnnexB.convert(avcc: avcc), [0, 0, 0, 1, 0x65, 0x88, 0, 0, 0, 1, 0x41])
    }

    func testPutsParameterSetsFirst() {
        let result = AnnexB.convert(avcc: [0, 0, 0, 1, 0x65], parameterSets: [[0x67, 1], [0x68, 2]])
        XCTAssertEqual(result, [0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2, 0, 0, 0, 1, 0x65])
    }

    func testStopsAtATruncatedUnit() {
        XCTAssertEqual(AnnexB.convert(avcc: [0, 0, 0, 5, 1, 2]), [])
        XCTAssertEqual(AnnexB.convert(avcc: [0, 0, 0, 1, 9, 0, 0]), [0, 0, 0, 1, 9])
    }
}
