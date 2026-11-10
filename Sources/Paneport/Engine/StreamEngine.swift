import AppKit
import ScreenCaptureKit

/// Owns the virtual displays, their streams, the pointer tracker and the receiver page,
/// and publishes their state to the UI.
@MainActor
final class StreamEngine: ObservableObject {
    @Published var settings: AppSettings {
        didSet { settingsDidChange() }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var statuses: [UUID: DisplayStatus] = [:]
    /// Non-fatal problems with a display, such as Retina mode being unavailable.
    @Published private(set) var warnings: [UUID: String] = [:]
    @Published private(set) var screens: [ScreenInfo] = []
    @Published var lastError: String?
    @Published private(set) var needsScreenRecordingPermission = false

    private let store: SettingsStore
    private var runningSettings: AppSettings?
    private var streamers: [DisplayStreamer] = []
    private var receiverServer: ReceiverServer?
    private var pointerTracker: PointerTracker?
    private var activity: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = store.load()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshScreens() }
        }
        refreshScreens()
        if settings.startOnLaunch {
            Task { await self.start() }
        }
    }

    // MARK: - Derived state

    /// Settings were changed in a way that needs the streams restarted.
    var needsRestart: Bool {
        guard isRunning, let runningSettings else { return false }
        return settings.requiresRestart(comparedTo: runningSettings)
    }

    var statusLine: String {
        guard isRunning else {
            let count = settings.displays.filter(\.enabled).count
            return "\(count) display\(count == 1 ? "" : "s") ready. Start, then open the receiver page on your PC."
        }
        let viewers = statuses.values.reduce(0) { $0 + $1.viewers }
        var line = "\(streamers.count) virtual display\(streamers.count == 1 ? "" : "s")"
            + " · \(viewers) viewer\(viewers == 1 ? "" : "s") connected"
        let delays = statuses.values.compactMap { $0.latency?.total }
        if !delays.isEmpty {
            line += " · ~\(Int((delays.reduce(0, +) / Double(delays.count)).rounded())) ms delay"
        }
        return line
    }

    var receiverURLs: [String] {
        NetworkInterfaces.localIPv4Addresses().map { "http://\($0):\(settings.basePort)/" }
    }

    // MARK: - Start and stop

    func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    func applyChanges() async {
        await stop()
        await start()
    }

    func start() async {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        warnings = [:]
        needsScreenRecordingPermission = false

        guard await checkScreenRecordingPermission() else { return }

        let snapshot = settings
        let configs = snapshot.displays.filter(\.enabled).map { $0.sanitized() }
        guard !configs.isEmpty else {
            lastError = "Turn on at least one display."
            return
        }

        do {
            streamers = try makeStreamers(configs, settings: snapshot)
            await selectDisplayModes()
            let server = ReceiverServer(port: snapshot.basePort, displays: streamers.map {
                .init(name: $0.config.name, port: $0.port, width: $0.config.width, height: $0.config.height)
            })
            try server.start()
            receiverServer = server
            for streamer in streamers { try await streamer.start() }
        } catch {
            lastError = "Could not start streaming: \(error.localizedDescription)"
            await teardown()
            return
        }

        runningSettings = snapshot
        isRunning = true
        if !snapshot.bakeCursor { startPointerTracker() }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Streaming virtual displays")
        refreshScreens()
        // macOS places new displays a moment after they're created.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshScreens() }
        Log.engine.info("Streaming \(self.streamers.count) display(s)")
    }

    func stop() async {
        guard isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await teardown()
    }

    private func teardown() async {
        pointerTracker?.stop()
        pointerTracker = nil
        receiverServer?.stop()
        receiverServer = nil
        for streamer in streamers { await streamer.stop() }
        streamers = []   // releases the virtual displays
        statuses = [:]
        isRunning = false
        runningSettings = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        refreshScreens()
    }

    /// Asks ScreenCaptureKit directly: CGPreflightScreenCaptureAccess() often reports
    /// "denied" on recent macOS even when permission is granted.
    private func checkScreenRecordingPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            needsScreenRecordingPermission = true
            lastError = PaneportError.screenCaptureBlocked(reason: error.localizedDescription).localizedDescription
            return false
        }
    }

    private func makeStreamers(_ configs: [DisplayConfig], settings: AppSettings) throws -> [DisplayStreamer] {
        try configs.enumerated().map { index, config in
            guard let display = VirtualDisplayFactory.make(config) else {
                throw PaneportError.virtualDisplayFailed(name: config.name)
            }
            let id = config.id
            return DisplayStreamer(
                config: config, port: settings.streamPort(forIndex: index), display: display,
                showsCursorInVideo: settings.bakeCursor
            ) { @Sendable [weak self] status in
                Task { @MainActor in self?.statuses[id] = status }
            }
        }
    }

    /// Puts HiDPI displays into their Retina mode. macOS lists a new display's modes
    /// a moment after it's created, hence the short wait.
    private func selectDisplayModes() async {
        let hiDPI = streamers.filter { $0.config.hiDPI }
        guard !hiDPI.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        for streamer in hiDPI {
            let selected = VirtualDisplayFactory.selectMode(for: streamer.displayID, config: streamer.config)
            guard !selected else { continue }
            warnings[streamer.config.id] =
                "macOS didn't offer a Retina mode at this size, so this display runs at standard resolution."
            Log.engine.notice("No HiDPI mode for \(streamer.config.name, privacy: .public)")
        }
    }

    private func startPointerTracker() {
        let tracker = PointerTracker(
            targets: streamers.map { .init(displayID: $0.displayID, streamWidth: $0.config.width, streamer: $0) },
            hideWhileTyping: settings.hidePointerWhileTyping)
        tracker.start()
        pointerTracker = tracker
    }

    private func settingsDidChange() {
        store.save(settings)
        pointerTracker?.hideWhileTyping = settings.hidePointerWhileTyping
    }

    // MARK: - Arrangement

    func refreshScreens() {
        let names = Dictionary(streamers.map { ($0.displayID, $0.config.name) }, uniquingKeysWith: { first, _ in first })
        screens = ScreenList.current(virtualNames: names)
    }

    /// Moves a display next to the nearest other display, edge to edge.
    func move(_ displayID: CGDirectDisplayID, to proposed: CGPoint) {
        guard let moving = screens.first(where: { $0.id == displayID }) else { return }
        let others = screens.filter { $0.id != displayID }.map(\.bounds)
        let origin = DisplayLayout.snappedOrigin(size: moving.bounds.size, proposed: proposed, others: others)
        DisplayLayout.move(displayID, to: origin)
        refreshScreens()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshScreens() }
    }
}
