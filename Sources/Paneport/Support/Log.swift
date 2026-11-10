import os

/// Loggers by area. View them in Console.app by filtering on the subsystem.
enum Log {
    static let engine = Logger(subsystem: AppInfo.bundleIdentifier, category: "engine")
    static let streaming = Logger(subsystem: AppInfo.bundleIdentifier, category: "streaming")
    static let web = Logger(subsystem: AppInfo.bundleIdentifier, category: "web")
}
