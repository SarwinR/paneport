/// Live state of one display's stream, shown in the settings window.
struct DisplayStatus: Equatable {
    var viewers = 0
    /// Frames sent in the last second (0 while the screen is still).
    var framesPerSecond = 0
    var latency: LatencyStats?
}

/// Averages over the last second as measured by a viewer, in milliseconds.
/// The viewer page sends these; the field names are part of the wire protocol.
struct LatencyStats: Codable, Equatable {
    /// Capture on the Mac to drawn in the browser.
    var total: Double?
    var encode: Double?
    var network: Double?
    var decode: Double?
    /// Drawn to the browser showing it on its next frame.
    var browser: Double?
    /// Pointer movement on the Mac to drawn on the PC (when the PC draws the pointer).
    var pointer: Double?
    var rtt: Double?
    var fps: Double?
    var mbps: Double?
    var drops: Int?
}
