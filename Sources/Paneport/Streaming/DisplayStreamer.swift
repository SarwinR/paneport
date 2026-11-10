import CoreMedia
import CVirtualDisplay
import Foundation
import ScreenCaptureKit

/// Streams one virtual display: ScreenCaptureKit capture → H.264 → WebSocket viewers.
///
/// Frames arrive only when the screen changes. When it stops changing, the last image
/// is re-encoded a few times so it sharpens to full quality, then the stream goes quiet.
/// All mutable state is confined to `queue`.
final class DisplayStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    let config: DisplayConfig
    let port: Int
    var displayID: CGDirectDisplayID { display.displayID }

    /// Re-encodes of a still image, so it sharpens to full quality.
    private static let refineFrames = 6
    private static let tickInterval: TimeInterval = 0.1
    private static let ticksPerSecond = 10

    private let display: CGVirtualDisplay   // the display exists only while this is alive
    private let showsCursorInVideo: Bool
    private let onStatus: @Sendable (DisplayStatus) -> Void
    private let queue: DispatchQueue
    private let server: ViewerServer

    private var encoder: H264Encoder?
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?

    // Encoding
    private var keyframeNeeded = true
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastEncodeDate = Date.distantPast
    private var refinesLeft = 0

    // Stats
    private var framesThisSecond = 0
    private var ticks = 0
    private var lastFramesPerSecond = 0
    private var lastLatency: LatencyStats?

    // Pointer, replayed to viewers that join later
    private var pointerShapeMessage: String?
    private var pointerPositionMessage: String?
    private var pointerVisibleHere = false

    init(config: DisplayConfig, port: Int, display: CGVirtualDisplay, showsCursorInVideo: Bool,
         onStatus: @escaping @Sendable (DisplayStatus) -> Void) {
        self.config = config
        self.port = port
        self.display = display
        self.showsCursorInVideo = showsCursorInVideo
        self.onStatus = onStatus
        let queue = DispatchQueue(label: "\(AppInfo.bundleIdentifier).stream.\(port)", qos: .userInteractive)
        self.queue = queue
        self.server = ViewerServer(port: port, queue: queue)
        super.init()
        server.onViewerJoined = { [weak self] viewer in self?.viewerJoined(viewer) }
        server.onViewerCountChanged = { [weak self] _ in self?.reportStatus() }
        server.onMessage = { [weak self] text, viewer in self?.handle(text, from: viewer) }
    }

    // MARK: - Start and stop

    func start() async throws {
        let encoder = try H264Encoder(width: config.width, height: config.height,
                                      fps: config.fps, bitrateMbps: config.mbps)
        try queue.sync {
            self.encoder = encoder
            try server.start()
        }

        let shareable = try await Self.shareableDisplay(displayID, name: config.name)
        let stream = SCStream(filter: SCContentFilter(display: shareable, excludingWindows: []),
                              configuration: captureConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()

        queue.sync {
            self.stream = stream
            startTimer()
        }
    }

    func stop() async {
        let stream = queue.sync { () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }
        if let stream { try? await stream.stopCapture() }
        queue.sync {
            timer?.cancel()
            timer = nil
            server.stop()
            encoder?.invalidate()
            encoder = nil
            lastPixelBuffer = nil
        }
    }

    // MARK: - Pointer (when the PC draws it)

    func setPointerShape(_ message: String) {
        queue.async {
            self.pointerShapeMessage = message
            self.server.broadcast(text: message)
        }
    }

    /// `position` is in stream pixels. Hidden positions are sent once, then suppressed.
    func setPointer(position: CGPoint, visible: Bool, at micros: UInt64) {
        queue.async {
            if !visible && !self.pointerVisibleHere { return }
            self.pointerVisibleHere = visible
            let message = WireProtocol.pointerPosition(
                x: Double(position.x), y: Double(position.y), visible: visible, micros: micros)
            self.pointerPositionMessage = message
            self.server.broadcast(text: message)
        }
    }

    // MARK: - Capture

    private func captureConfiguration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = config.width   // pixels, so HiDPI displays are captured at full sharpness
        c.height = config.height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.queueDepth = 4
        c.showsCursor = showsCursorInVideo
        return c
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Sample buffers without an image mean "nothing changed".
        guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPixelBuffer = pixelBuffer
        refinesLeft = Self.refineFrames
        encode(pixelBuffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.streaming.error("\(self.config.name, privacy: .public): capture stopped: \(error.localizedDescription, privacy: .public)")
    }

    /// ScreenCaptureKit lists a new display a moment after it's created.
    private static func shareableDisplay(_ id: CGDirectDisplayID, name: String) async throws -> SCDisplay {
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let display = content.displays.first(where: { $0.displayID == id }) { return display }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw PaneportError.displayNeverAppeared(name: name)
    }

    // MARK: - Encode and send

    private func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let encoder, server.viewerCount > 0 else { return }
        let forceKeyframe = keyframeNeeded
        keyframeNeeded = false
        lastEncodeDate = Date()
        encoder.encode(pixelBuffer, presentationTime: time, forceKeyframe: forceKeyframe) { [weak self] output in
            guard let self, let frame = AnnexB.frame(from: output) else { return }
            var message = WireProtocol.frameHeader(isKeyframe: frame.isKeyframe,
                                                   capturedMicros: Self.captureMicros(of: output))
            message.append(contentsOf: frame.bytes)
            self.queue.async { self.send(message, isKeyframe: frame.isKeyframe) }
        }
    }

    private func send(_ frame: Data, isKeyframe: Bool) {
        let stamped = WireProtocol.stampingSendTime(HostClock.nowMicros(), on: frame)
        let result = server.broadcast(frame: stamped, isKeyframe: isKeyframe)
        if result.deliveredToAny { framesThisSecond += 1 }
        if result.keyframeNeeded { keyframeNeeded = true }
    }

    /// When a frame was captured, or "now" if its timestamp looks wrong.
    private static func captureMicros(of sampleBuffer: CMSampleBuffer) -> UInt64 {
        let now = HostClock.nowMicros()
        let captured = HostClock.micros(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let plausible = captured > 0 && captured <= now && now - captured < 5_000_000
        return plausible ? captured : now
    }

    private func requestKeyframe() {
        keyframeNeeded = true
        refinesLeft = Self.refineFrames
        if let lastPixelBuffer { encode(lastPixelBuffer, at: HostClock.now()) }
    }

    // MARK: - Timer: refining still images and once-a-second stats

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        if server.viewerCount > 0, refinesLeft > 0, let lastPixelBuffer,
           Date().timeIntervalSince(lastEncodeDate) > Self.tickInterval {
            refinesLeft -= 1
            encode(lastPixelBuffer, at: HostClock.now())
        }

        ticks += 1
        if ticks >= Self.ticksPerSecond {
            ticks = 0
            lastFramesPerSecond = framesThisSecond
            framesThisSecond = 0
            if server.viewerCount == 0 { lastLatency = nil }
            reportStatus()
        }
    }

    // MARK: - Viewers

    private func viewerJoined(_ viewer: ViewerServer.Viewer) {
        let hello = WireProtocol.Hello(protocolVersion: WireProtocol.version, appVersion: AppInfo.version,
                                       name: config.name, width: config.width, height: config.height)
        server.send(text: WireProtocol.hello(hello), to: viewer)
        if let pointerShapeMessage { server.send(text: pointerShapeMessage, to: viewer) }
        if let pointerPositionMessage { server.send(text: pointerPositionMessage, to: viewer) }
        requestKeyframe()
    }

    private func handle(_ text: String, from viewer: ViewerServer.Viewer) {
        switch WireProtocol.parse(viewerMessage: text) {
        case .ping(let payload):
            server.send(text: WireProtocol.pong(echo: payload, macMicros: HostClock.nowMicros()), to: viewer)
        case .stats(let stats):
            lastLatency = stats
            reportStatus()
        case .keyframeRequest:
            requestKeyframe()
        case .unknown:
            break
        }
    }

    private func reportStatus() {
        onStatus(DisplayStatus(viewers: server.viewerCount, framesPerSecond: lastFramesPerSecond,
                               latency: lastLatency))
    }
}
