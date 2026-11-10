import Foundation

/// Files the Mac serves to the PC: the viewer page and its scripts (Resources/receiver),
/// and, in release builds, the Windows receiver app (Contents/Resources/downloads).
///
/// While developing, set `PANEPORT_RECEIVER_DIR` to the Resources/receiver folder's path to
/// serve the page straight from disk: edits show up on the next page load without rebuilding.
enum ReceiverAssets {
    static var pageTemplate: String { load("index.html") }

    /// protocol.js and receiver.js joined; saved pages load this on every open.
    static var script: String { load("protocol.js") + "\n" + load("receiver.js") }

    /// The Windows receiver bundled with this build, if any. make-app.sh adds it when it
    /// finds a built receiver; release builds always include it.
    static let windowsReceiver: WindowsReceiverDownload? = WindowsReceiverDownload.loadBundled()

    private static let directoryName = "receiver"

    private static func load(_ name: String) -> String {
        if let directory = ProcessInfo.processInfo.environment["PANEPORT_RECEIVER_DIR"] {
            let path = (directory as NSString).appendingPathComponent(name)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }
        }
        if let url = bundledURL(name), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        Log.web.error("Receiver file \(name, privacy: .public) is missing")
        return ""
    }

    /// Packaged app: Contents/Resources/receiver (copied by make-app.sh).
    /// `swift run`: SwiftPM's resource bundle next to the executable.
    private static func bundledURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: nil, subdirectory: directoryName)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: directoryName)
    }
}

/// The Windows receiver executable and its version, offered for download to the PC.
struct WindowsReceiverDownload {
    static let fileName = "PaneportReceiver.exe"
    static let path = "/download/windows"

    let data: Data
    let version: String

    /// Reads Contents/Resources/downloads/PaneportReceiver.exe and the version file
    /// next to it (PaneportReceiver.version), as written by make-app.sh.
    static func loadBundled() -> WindowsReceiverDownload? {
        guard let exe = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "downloads"),
              let data = try? Data(contentsOf: exe)
        else { return nil }
        let versionURL = exe.deletingPathExtension().appendingPathExtension("version")
        let version = (try? String(contentsOf: versionURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return WindowsReceiverDownload(data: data, version: version)
    }
}
