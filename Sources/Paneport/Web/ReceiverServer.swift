import Foundation
import Network

/// A tiny HTTP server for the PC side:
///
///     /                  the viewer page, which the PC saves once (browsers only decode video on local pages)
///     /receiver.js       the current script, which saved pages load each time they open
///     /displays.json     the displays being streamed and their ports
///     /version           app and protocol versions, and whether a Windows receiver can be downloaded
///     /download/windows  the Windows receiver app, when this build includes it
final class ReceiverServer {
    struct DisplayEntry: Encodable {
        let name: String
        let port: Int
        let width: Int
        let height: Int
    }

    /// The /version response.
    struct VersionInfo: Codable, Equatable {
        struct Download: Codable, Equatable {
            let version: String
            let path: String
        }

        let appVersion: String
        let protocolVersion: Int
        let windowsReceiver: Download?

        enum CodingKeys: String, CodingKey {
            case appVersion = "app"
            case protocolVersion = "protocol"
            case windowsReceiver
        }

        static var current: VersionInfo {
            VersionInfo(
                appVersion: AppInfo.version,
                protocolVersion: WireProtocol.version,
                windowsReceiver: ReceiverAssets.windowsReceiver.map {
                    Download(version: $0.version, path: WindowsReceiverDownload.path)
                })
        }
    }

    private let port: Int
    private let displaysJSON: Data
    private let queue = DispatchQueue(label: "\(AppInfo.bundleIdentifier).receiver-server")
    private var listener: NWListener?

    init(port: Int, displays: [DisplayEntry]) {
        self.port = port
        self.displaysJSON = (try? JSONEncoder().encode(displays)) ?? Data("[]".utf8)
    }

    func start() throws {
        guard AppSettings.portRange.contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw PaneportError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Private

    /// Requests larger than this are answered as they are; ours are a few hundred bytes.
    private static let maxRequestSize = 64 * 1024

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, received: Data())
    }

    /// Reads until the request head is complete, then answers. A request can arrive in
    /// several packets; answering early and closing while the rest is still unread makes
    /// TCP reset the connection, so the client never gets the response.
    private func receiveRequest(on connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestSize) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = received
            if let data { request.append(data) }
            let keepReading = !Self.isCompleteRequestHead(request) && !isComplete && error == nil
                && request.count < Self.maxRequestSize
            if keepReading {
                self.receiveRequest(on: connection, received: request)
                return
            }
            let response = self.response(for: HTTPRequestHead(request))
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Whether `data` holds a whole HTTP request head (it ends with a blank line).
    static func isCompleteRequestHead(_ data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    private func response(for request: HTTPRequestHead) -> Data {
        switch request.path {
        case "/displays.json":
            return Self.httpResponse(body: displaysJSON, contentType: "application/json")
        case "/version":
            let body = (try? JSONEncoder().encode(VersionInfo.current)) ?? Data("{}".utf8)
            return Self.httpResponse(body: body, contentType: "application/json")
        case WindowsReceiverDownload.path:
            guard let download = ReceiverAssets.windowsReceiver else {
                return Self.httpResponse(status: "404 Not Found", body: Data("This build has no Windows receiver.".utf8),
                                         contentType: "text/plain; charset=utf-8")
            }
            return Self.httpResponse(
                body: download.data, contentType: "application/octet-stream",
                extraHeaders: ["Content-Disposition: attachment; filename=\"\(WindowsReceiverDownload.fileName)\""])
        case "/receiver.js":
            return Self.httpResponse(body: Data(ReceiverAssets.script.utf8),
                                     contentType: "text/javascript; charset=utf-8")
        default:
            let page = Self.renderPage(
                template: ReceiverAssets.pageTemplate,
                host: Self.pageHost(requestHost: request.host, port: port),
                displaysJSON: displaysJSON,
                script: ReceiverAssets.script)
            return Self.httpResponse(body: Data(page.utf8), contentType: "text/html; charset=utf-8")
        }
    }

    /// Fills the page template's placeholders: __HOST__, __DISPLAYS__ and __SCRIPT__.
    static func renderPage(template: String, host: String, displaysJSON: Data, script: String) -> String {
        // The display list goes inside a <script> tag, so "<" must not close it early.
        let displays = String(decoding: displaysJSON, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
        return template
            .replacingOccurrences(of: "__HOST__", with: host)
            .replacingOccurrences(of: "__DISPLAYS__", with: displays)
            .replacingOccurrences(of: "__SCRIPT__", with: script)
    }

    /// The address the page should talk back to: the host the browser used, with the port.
    /// Only characters valid in a host name survive, since it is placed into the page.
    static func pageHost(requestHost: String?, port: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        let host = (requestHost ?? "").filter { allowed.contains($0) }
        return host.contains(":") ? host : "\(host):\(port)"
    }

    static func httpResponse(status: String = "200 OK", body: Data, contentType: String,
                             extraHeaders: [String] = []) -> Data {
        var lines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",   // saved pages (file://) fetch from here
            "Cache-Control: no-store",
            "Connection: close",
        ]
        lines += extraHeaders
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }
}

/// The parts of an HTTP request the server needs.
struct HTTPRequestHead: Equatable {
    var path = "/"
    var host: String?

    init(_ data: Data?) {
        guard let data, let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline)
        if let requestLine = lines.first {
            let parts = requestLine.split(separator: " ")
            if parts.count > 1, let target = parts[1].split(separator: "?", omittingEmptySubsequences: false).first {
                path = String(target)
            }
        }
        for line in lines.dropFirst() where line.lowercased().hasPrefix("host:") {
            host = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        }
    }
}
