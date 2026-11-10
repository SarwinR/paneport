import Foundation
import Network

/// WebSocket server for the viewers of one display.
/// Everything, callbacks included, runs on the queue passed to `init`.
final class ViewerServer {
    final class Viewer {
        fileprivate let connection: NWConnection
        /// Frames handed to the network but not yet sent.
        fileprivate var framesInFlight = 0
        /// Delta frames are useless until the viewer has the keyframe they build on.
        fileprivate var waitingForKeyframe = true

        fileprivate init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    struct BroadcastResult {
        var deliveredToAny = false
        /// A viewer fell behind and skipped ahead; the next frame should be a keyframe.
        var keyframeNeeded = false
    }

    /// A viewer with more frames than this still queued is falling behind. It skips to
    /// the next keyframe instead of building up delay.
    static let maxFramesInFlight = 4

    var onViewerJoined: ((Viewer) -> Void)?
    var onViewerCountChanged: ((Int) -> Void)?
    var onMessage: ((String, Viewer) -> Void)?

    var viewerCount: Int { viewers.count }

    private let port: Int
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var viewers: [Viewer] = []

    init(port: Int, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    func start() throws {
        guard AppSettings.portRange.contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw PaneportError.invalidPort(port)
        }
        let listener = try NWListener(using: Self.parameters(), on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for viewer in viewers {
            viewer.connection.stateUpdateHandler = nil
            viewer.connection.cancel()
        }
        viewers.removeAll()
    }

    func send(text: String, to viewer: Viewer) {
        send(Data(text.utf8), opcode: .text, to: viewer)
    }

    func broadcast(text: String) {
        for viewer in viewers { send(text: text, to: viewer) }
    }

    func broadcast(frame: Data, isKeyframe: Bool) -> BroadcastResult {
        var result = BroadcastResult()
        for viewer in viewers {
            if viewer.waitingForKeyframe && !isKeyframe { continue }
            if viewer.framesInFlight > Self.maxFramesInFlight {
                viewer.waitingForKeyframe = true
                result.keyframeNeeded = true
                continue
            }
            viewer.waitingForKeyframe = false
            viewer.framesInFlight += 1
            result.deliveredToAny = true
            // Completions run on `queue`, the connection's queue.
            send(frame, opcode: .binary, to: viewer) { viewer.framesInFlight -= 1 }
        }
        return result
    }

    // MARK: - Private

    private func accept(_ connection: NWConnection) {
        let viewer = Viewer(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.viewers.append(viewer)
                self.onViewerCountChanged?(self.viewers.count)
                self.onViewerJoined?(viewer)
                self.receive(from: viewer)
            case .failed, .cancelled:
                self.remove(viewer)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ viewer: Viewer) {
        viewer.connection.stateUpdateHandler = nil   // breaks the handler → viewer → connection cycle
        guard let index = viewers.firstIndex(where: { $0 === viewer }) else { return }
        viewers.remove(at: index)
        onViewerCountChanged?(viewers.count)
    }

    private func receive(from viewer: Viewer) {
        viewer.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil || (data == nil && context == nil) {
                viewer.connection.cancel()
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                viewer.connection.cancel()
                return
            }
            if let data {
                self.onMessage?(String(decoding: data, as: UTF8.self), viewer)
            }
            self.receive(from: viewer)
        }
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, to viewer: Viewer,
                      completion: (() -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        viewer.connection.send(content: data, contentContext: context, isComplete: true,
                               completion: .contentProcessed { _ in completion?() })
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true   // send small messages (pointer, pings) immediately
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 16 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }
}
