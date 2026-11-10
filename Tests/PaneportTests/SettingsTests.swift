import XCTest
@testable import Paneport

final class SettingsTests: XCTestCase {
    func testLoadsSettingsSavedByOlderVersions() throws {
        // As saved before the pointer and Retina options existed.
        let json = #"""
        {"displays":[{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Left","enabled":true,
        "width":2560,"height":1440,"fps":60,"mbps":30,"serial":7}],"basePort":9000,"startOnLaunch":true}
        """#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.basePort, 9000)
        XCTAssertTrue(settings.startOnLaunch)
        XCTAssertFalse(settings.bakeCursor)
        XCTAssertTrue(settings.hidePointerWhileTyping)
        XCTAssertEqual(settings.displays.count, 1)
        XCTAssertEqual(settings.displays[0].name, "Left")
        XCTAssertEqual(settings.displays[0].serial, 7)
        XCTAssertFalse(settings.displays[0].hiDPI)
    }

    func testSanitizedClampsToSupportedValues() {
        var config = DisplayConfig(name: "  ")
        config.width = 100_001
        config.height = 1
        config.fps = 500
        config.mbps = 0
        let sanitized = config.sanitized()
        XCTAssertEqual(sanitized.width, DisplayConfig.widthRange.upperBound)
        XCTAssertEqual(sanitized.height, DisplayConfig.heightRange.lowerBound)
        XCTAssertEqual(sanitized.fps, DisplayConfig.fpsRange.upperBound)
        XCTAssertEqual(sanitized.mbps, DisplayConfig.mbpsRange.lowerBound)
        XCTAssertEqual(sanitized.name, DisplayConfig.defaultName)
    }

    func testSanitizedKeepsHiDPISizesDivisibleByFour() {
        var config = DisplayConfig(name: "A")
        config.hiDPI = true
        config.width = 2562
        config.height = 1442
        let sanitized = config.sanitized()
        XCTAssertEqual(sanitized.width % 4, 0)
        XCTAssertEqual(sanitized.height % 4, 0)
    }

    func testHiDPIPointSizeIsHalf() {
        var config = DisplayConfig(name: "A")
        config.width = 3840
        config.height = 2160
        XCTAssertEqual(config.pointSize.width, 3840)
        config.hiDPI = true
        XCTAssertEqual(config.pointSize.width, 1920)
        XCTAssertEqual(config.pointSize.height, 1080)
    }

    func testOnlyStreamSettingsRequireARestart() {
        let running = AppSettings.defaults
        var changed = running
        changed.startOnLaunch.toggle()
        changed.hidePointerWhileTyping.toggle()
        XCTAssertFalse(changed.requiresRestart(comparedTo: running))
        changed.bakeCursor.toggle()
        XCTAssertTrue(changed.requiresRestart(comparedTo: running))
    }

    func testLoadsSettingsFromBeforeTheRename() throws {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let legacySuite = suite + "-legacy"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            legacy.removePersistentDomain(forName: legacySuite)
        }
        var old = AppSettings.defaults
        old.basePort = 9200
        legacy.set(try JSONEncoder().encode(old), forKey: "old")

        let store = SettingsStore(defaults: defaults, key: "settings", legacyDefaults: legacy, legacyKey: "old")
        XCTAssertEqual(store.load().basePort, 9200)
    }

    func testStoreRoundTrip() throws {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults, key: "settings", legacyDefaults: nil)

        XCTAssertEqual(store.load().displays.count, AppSettings.defaults.displays.count)
        var settings = AppSettings.defaults
        settings.basePort = 9100
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }
}
