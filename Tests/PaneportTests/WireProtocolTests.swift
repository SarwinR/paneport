import XCTest
@testable import Paneport

final class WireProtocolTests: XCTestCase {
    func testFrameHeaderLayout() {
        let header = WireProtocol.frameHeader(isKeyframe: true, capturedMicros: 0x0102_0304_0506_0708)
        XCTAssertEqual(header.count, WireProtocol.frameHeaderSize)
        XCTAssertEqual(Array(header), [1, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testStampingSendTimeKeepsTheRest() {
        var frame = WireProtocol.frameHeader(isKeyframe: false, capturedMicros: 7)
        frame.append(contentsOf: [0xAA, 0xBB])
        let stamped = WireProtocol.stampingSendTime(0x0A0B, on: frame)
        XCTAssertEqual(Array(stamped), [0, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0x0A, 0x0B, 0xAA, 0xBB])
    }

    func testPointerPositionFormat() {
        XCTAssertEqual(WireProtocol.pointerPosition(x: 10, y: 20.5, visible: true, micros: 123),
                       "m:10.0,20.5,1,123")
        XCTAssertEqual(WireProtocol.pointerPosition(x: 0, y: 0, visible: false, micros: 1), "m:0.0,0.0,0,1")
    }

    func testPongEchoesThePing() {
        XCTAssertEqual(WireProtocol.pong(echo: "12.5", macMicros: 99), "q:12.5:99")
    }

    func testHelloUsesTheDocumentedKeys() throws {
        let hello = WireProtocol.Hello(protocolVersion: 1, appVersion: "0.4.0", name: "Left", width: 1920, height: 1080)
        let message = WireProtocol.hello(hello)
        XCTAssertTrue(message.hasPrefix("h:"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.dropFirst(2).utf8)) as? [String: Any])
        XCTAssertEqual(json["protocol"] as? Int, 1)
        XCTAssertEqual(json["app"] as? String, "0.4.0")
        XCTAssertEqual(json["name"] as? String, "Left")
        XCTAssertEqual(json["width"] as? Int, 1920)
    }

    func testParsesViewerMessages() {
        XCTAssertEqual(WireProtocol.parse(viewerMessage: "p:12.5"), .ping(payload: "12.5"))
        XCTAssertEqual(WireProtocol.parse(viewerMessage: "k"), .keyframeRequest)
        XCTAssertEqual(WireProtocol.parse(viewerMessage: "zz"), .unknown)
        XCTAssertEqual(WireProtocol.parse(viewerMessage: "s:not json"), .unknown)

        var expected = LatencyStats()
        expected.total = 9.5
        expected.drops = 2
        XCTAssertEqual(WireProtocol.parse(viewerMessage: #"s:{"total":9.5,"drops":2,"pointer":null}"#),
                       .stats(expected))
    }
}
