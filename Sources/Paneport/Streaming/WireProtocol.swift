import Foundation

/// Messages between the Mac and a viewer page, over one WebSocket per display.
/// docs/PROTOCOL.md describes the format; Resources/receiver/protocol.js is the other side.
enum WireProtocol {

    /// Raised whenever a message changes incompatibly. Clients compare it with their own
    /// and tell the user to update instead of failing in confusing ways.
    static let version = 1

    // MARK: - Hello (text, Mac → viewer, first message on every connection)

    struct Hello: Codable, Equatable {
        /// `WireProtocol.version` of the Mac.
        let protocolVersion: Int
        let appVersion: String
        let name: String
        let width: Int
        let height: Int

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case appVersion = "app"
            case name, width, height
        }
    }

    /// "h:<json>": who is streaming and at what size, so clients can check compatibility
    /// and set up their decoder before the first frame.
    static func hello(_ hello: Hello) -> String {
        let json = (try? JSONEncoder().encode(hello)) ?? Data("{}".utf8)
        return "h:" + String(decoding: json, as: UTF8.self)
    }

    // MARK: - Video frames (binary, Mac → viewer)

    /// Flag (1 byte) + capture time (8) + send time (8). Times are big-endian
    /// microseconds on the Mac host clock. The H.264 data (Annex B) follows.
    static let frameHeaderSize = 17
    private static let sendTimeOffset = 9

    /// Header for a frame; the send time is filled in later by `stampingSendTime`.
    static func frameHeader(isKeyframe: Bool, capturedMicros: UInt64) -> Data {
        var header = Data(capacity: frameHeaderSize)
        header.append(isKeyframe ? 1 : 0)
        header.append(contentsOf: bigEndianBytes(capturedMicros))
        header.append(contentsOf: bigEndianBytes(0))
        return header
    }

    /// A copy of `frame` with its send time set.
    static func stampingSendTime(_ micros: UInt64, on frame: Data) -> Data {
        var stamped = frame
        let start = stamped.startIndex + sendTimeOffset
        stamped.replaceSubrange(start..<(start + 8), with: bigEndianBytes(micros))
        return stamped
    }

    static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
    }

    // MARK: - Text messages, Mac → viewer

    /// Reply to a ping: echoes the viewer's timestamp and adds the Mac's clock.
    static func pong(echo payload: String, macMicros: UInt64) -> String {
        "q:\(payload):\(macMicros)"
    }

    /// Pointer position in stream pixels; `visible` is false when it's on another display.
    static func pointerPosition(x: Double, y: Double, visible: Bool, micros: UInt64) -> String {
        "m:" + String(format: "%.1f,%.1f,%d,", x, y, visible ? 1 : 0) + String(micros)
    }

    /// Pointer image: JSON with png (base64), w, h, hx, hy in stream pixels.
    static func pointerShape(json: String) -> String {
        "c:" + json
    }

    // MARK: - Text messages, viewer → Mac

    enum ViewerMessage: Equatable {
        /// "p:<viewer time>": clock sync request.
        case ping(payload: String)
        /// "s:<json>": the viewer's latency measurements for the last second.
        case stats(LatencyStats)
        /// "k": the viewer lost sync and needs a keyframe.
        case keyframeRequest
        case unknown
    }

    static func parse(viewerMessage text: String) -> ViewerMessage {
        if text.hasPrefix("p:") {
            return .ping(payload: String(text.dropFirst(2)))
        }
        if text.hasPrefix("s:") {
            let json = Data(text.dropFirst(2).utf8)
            guard let stats = try? JSONDecoder().decode(LatencyStats.self, from: json) else { return .unknown }
            return .stats(stats)
        }
        if text == "k" {
            return .keyframeRequest
        }
        return .unknown
    }
}
