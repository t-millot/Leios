import XCTest
@testable import LeiosShared

final class ConfigCodableTests: XCTestCase {

    func testRoundTrip() throws {
        var config = LeiosConfig()
        config.scroll.smoothness = .regular
        config.scroll.modifiers.zoom = 0
        config.buttons[7] = ButtonMapping(click: .navigateBack, hold: .symbolicHotkey(.missionControl), drag: .twoFingerSwipe)
        let data = try ConfigFile.encode(config)
        let decoded = try ConfigFile.decode(data)
        XCTAssertEqual(decoded, config)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try ConfigFile.decode(Data("{}".utf8))
        XCTAssertEqual(decoded, LeiosConfig())
        XCTAssertEqual(decoded.scroll.smoothness, .high)
        XCTAssertEqual(decoded.buttons[4]?.drag, .threeFingerSwipe)
    }

    func testPartialObjectsUseDefaults() throws {
        let json = #"{"scroll":{"speed":"low"},"buttons":{"3":{"click":{"smartZoom":{}}}},"general":{"showMenuBarItem":true}}"#
        let decoded = try ConfigFile.decode(Data(json.utf8))
        XCTAssertEqual(decoded.scroll.speed, .low)
        XCTAssertEqual(decoded.scroll.smoothness, .high)
        XCTAssertEqual(decoded.buttons[3]?.click, .smartZoom)
        XCTAssertNil(decoded.buttons[4])
        XCTAssertTrue(decoded.general.showMenuBarItem)
        XCTAssertTrue(decoded.general.scrollingEnabled)
    }

    func testAppProfilesRoundTrip() throws {
        var config = LeiosConfig()
        config.apps["com.apple.Safari"] = AppProfile(name: "Safari")
        config.apps["com.apple.Safari"]?.scroll.speed = .high
        config.apps["com.apple.Safari"]?.scroll.modifiers = ScrollModifierFlags()
        let data = try ConfigFile.encode(config)
        let decoded = try ConfigFile.decode(data)
        XCTAssertEqual(decoded, config)
    }

    /// Unset overrides must be omitted, not written as nulls — the JSON is what tells you at a
    /// glance which fields an app has actually pinned.
    func testUnsetOverridesAreOmitted() throws {
        var config = LeiosConfig()
        config.apps["com.apple.Safari"] = AppProfile(name: "Safari")
        config.apps["com.apple.Safari"]?.scroll.speed = .high
        let data = try ConfigFile.encode(config)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"speed\" : \"high\""))
        XCTAssertFalse(json.contains("null"))
    }

    func testPartialAppProfileKeepsOtherFieldsUnset() throws {
        let json = #"{"apps":{"com.apple.Safari":{"scroll":{"speed":"high"}}}}"#
        let decoded = try ConfigFile.decode(Data(json.utf8))
        let overrides = try XCTUnwrap(decoded.apps["com.apple.Safari"]).scroll
        XCTAssertEqual(overrides.speed, .high)
        XCTAssertNil(overrides.smoothness)
        XCTAssertNil(overrides.modifiers)
        // An untouched field still follows the global setting.
        XCTAssertEqual(overrides.resolved(against: decoded.scroll).smoothness, decoded.scroll.smoothness)
    }

    func testMissingAppsKeyDecodesToEmpty() throws {
        XCTAssertTrue(try ConfigFile.decode(Data("{}".utf8)).apps.isEmpty)
        XCTAssertTrue(try ConfigFile.decode(Data(#"{"apps":{}}"#.utf8)).apps.isEmpty)
    }

    func testEmptyBundleIdentifierIsDropped() throws {
        let json = #"{"apps":{"":{"name":"Nothing"},"com.apple.Safari":{"name":"Safari"}}}"#
        let decoded = try ConfigFile.decode(Data(json.utf8))
        XCTAssertEqual(decoded.apps.keys.sorted(), ["com.apple.Safari"])
    }

    func testInvalidButtonKeysAreDropped() throws {
        let json = #"{"buttons":{"abc":{},"99":{},"5":{"drag":"twoFingerSwipe"}}}"#
        let decoded = try ConfigFile.decode(Data(json.utf8))
        XCTAssertEqual(decoded.buttons.keys.sorted(), [5])
    }
}
