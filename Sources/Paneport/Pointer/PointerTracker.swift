import AppKit

/// Sends the Mac's pointer to the streamers, so viewers draw it themselves instead of
/// waiting for it to arrive inside the video.
///
/// Position updates are event-driven: every mouse movement is forwarded as it happens.
/// A slower timer catches what produces no mouse event: pointer warps, shape changes,
/// and the pointer hiding while you type. Neither needs extra permissions.
///
/// Use from the main thread.
final class PointerTracker {
    struct Target {
        let displayID: CGDirectDisplayID
        /// Stream width in pixels, to convert points to stream pixels.
        let streamWidth: Int
        let streamer: DisplayStreamer
    }

    /// Takes effect immediately.
    var hideWhileTyping: Bool {
        didSet { update(force: true) }
    }

    private static let movementEvents: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    private static let movementEventTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    private static let slowCheckInterval: TimeInterval = 0.05

    private let targets: [Target]
    private var monitors: [Any] = []
    private var timer: Timer?
    private var lastLocation: CGPoint?
    private var lastHidden = false
    private var lastShape: PointerShape?

    init(targets: [Target], hideWhileTyping: Bool) {
        self.targets = targets
        self.hideWhileTyping = hideWhileTyping
    }

    func start() {
        // Global monitors see events going to other apps; local ones see our own.
        // Mouse events (unlike key events) need no Accessibility permission.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: Self.movementEvents, handler: { [weak self] _ in
            self?.update(hidden: false)
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: Self.movementEvents, handler: { [weak self] event in
            self?.update(hidden: false)
            return event
        }) {
            monitors.append(monitor)
        }

        let timer = Timer(timeInterval: Self.slowCheckInterval, repeats: true) { [weak self] _ in
            self?.slowCheck()
        }
        RunLoop.main.add(timer, forMode: .common)   // keep running while menus are open
        self.timer = timer
        slowCheck()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        timer?.invalidate()
        timer = nil
        let now = HostClock.nowMicros()
        for target in targets {
            target.streamer.setPointer(position: .zero, visible: false, at: now)
        }
    }

    // MARK: - Private

    private func slowCheck() {
        updateShape()
        update()
    }

    /// Sends the current position to every display. `hidden` overrides the typing check
    /// (a mouse movement always shows the pointer).
    private func update(hidden: Bool? = nil, force: Bool = false) {
        guard let location = CGEvent(source: nil)?.location else { return }
        let isHidden = hidden ?? isHiddenByTyping()
        if !force, location == lastLocation, isHidden == lastHidden { return }
        lastLocation = location
        lastHidden = isHidden

        let now = HostClock.nowMicros()
        for target in targets {
            let placement = PointerMath.streamPosition(
                of: location, displayBounds: CGDisplayBounds(target.displayID), streamWidth: target.streamWidth)
            target.streamer.setPointer(position: placement.position,
                                       visible: placement.isInside && !isHidden, at: now)
        }
    }

    private func isHiddenByTyping() -> Bool {
        guard hideWhileTyping else { return false }
        let state = CGEventSourceStateID.combinedSessionState
        let sinceKey = CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown)
        let sinceMove = Self.movementEventTypes
            .map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }
            .min() ?? .infinity
        return PointerMath.isHiddenByTyping(secondsSinceKeyDown: sinceKey, secondsSinceMouseMoved: sinceMove)
    }

    private func updateShape() {
        guard let shape = PointerShape.current(), shape != lastShape else { return }
        lastShape = shape
        for target in targets {
            let scale = PointerMath.scale(displayBounds: CGDisplayBounds(target.displayID),
                                          streamWidth: target.streamWidth)
            if let message = shape.message(scale: scale) {
                target.streamer.setPointerShape(message)
            }
        }
    }
}
