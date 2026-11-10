import XCTest
@testable import Paneport

final class ReceiverServerTests: XCTestCase {
    func testParsesTheRequestHead() {
        let request = HTTPRequestHead(Data("GET /displays.json?t=1 HTTP/1.1\r\nHost: 10.0.0.2:8080\r\n\r\n".utf8))
        XCTAssertEqual(request.path, "/displays.json")
        XCTAssertEqual(request.host, "10.0.0.2:8080")
    }

    func testWaitsForTheWholeRequestHead() {
        XCTAssertFalse(ReceiverServer.isCompleteRequestHead(Data("GET ".utf8)))
        XCTAssertFalse(ReceiverServer.isCompleteRequestHead(Data("GET /version HTTP/1.1\r\nHost: x\r\n".utf8)))
        XCTAssertTrue(ReceiverServer.isCompleteRequestHead(Data("GET /version HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
    }

    func testDefaultsForAnUnreadableRequest() {
        let request = HTTPRequestHead(nil)
        XCTAssertEqual(request.path, "/")
        XCTAssertNil(request.host)
    }

    func testPageHostAddsThePortAndDropsUnsafeCharacters() {
        XCTAssertEqual(ReceiverServer.pageHost(requestHost: "10.0.0.2", port: 8080), "10.0.0.2:8080")
        XCTAssertEqual(ReceiverServer.pageHost(requestHost: "10.0.0.2:9000", port: 8080), "10.0.0.2:9000")
        XCTAssertEqual(ReceiverServer.pageHost(requestHost: "a\"><b>", port: 8080), "ab:8080")
    }

    func testVersionInfoUsesTheDocumentedKeys() throws {
        let info = ReceiverServer.VersionInfo(
            appVersion: "0.4.0", protocolVersion: 1,
            windowsReceiver: ReceiverServer.VersionInfo.Download(version: "0.1.0", path: "/download/windows"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        XCTAssertEqual(json["app"] as? String, "0.4.0")
        XCTAssertEqual(json["protocol"] as? Int, 1)
        let receiver = try XCTUnwrap(json["windowsReceiver"] as? [String: Any])
        XCTAssertEqual(receiver["version"] as? String, "0.1.0")
        XCTAssertEqual(receiver["path"] as? String, "/download/windows")
    }

    func testHTTPResponseHead() {
        let response = ReceiverServer.httpResponse(status: "404 Not Found", body: Data("no".utf8),
                                                   contentType: "text/plain", extraHeaders: ["X-Test: 1"])
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.contains("X-Test: 1\r\n\r\nno"))
    }

    func testRenderPageFillsPlaceholdersAndEscapesTheDisplayList() {
        let page = ReceiverServer.renderPage(
            template: "host=__HOST__ list=__DISPLAYS__ code=__SCRIPT__",
            host: "1.2.3.4:8080",
            displaysJSON: Data(#"[{"name":"</script>"}]"#.utf8),
            script: "run()")
        // "<" becomes "\u003c" so a display name can't end the page's <script> tag.
        let escapedName = #"\u003c/script>"#   // raw string: a literal backslash-u
        XCTAssertEqual(page, "host=1.2.3.4:8080 list=[{\"name\":\"\(escapedName)\"}] code=run()")
    }
}
