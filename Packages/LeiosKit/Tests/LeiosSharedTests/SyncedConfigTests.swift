import XCTest
@testable import LeiosShared

final class SyncedConfigTests: XCTestCase {

    func testProjectionRoundTrip() throws {
        var config = LeiosConfig()
        config.scroll.smoothness = .regular
        config.scroll.modifiers.zoom = 0
        config.buttons[7] = ButtonMapping(click: .navigateBack, hold: .symbolicHotkey(.missionControl), drag: .twoFingerSwipe)
        config.general.lockPointerDuringDrag = true
        config.apps["com.apple.Safari"] = AppProfile(name: "Safari")
        config.apps["com.apple.Safari"]?.scroll.speed = .high

        let data = try SyncedConfig.encode(SyncedConfig(config))
        let decoded = try SyncedConfig.decode(data)
        var fresh = LeiosConfig()
        decoded.apply(to: &fresh)

        XCTAssertEqual(fresh.scroll, config.scroll)
        XCTAssertEqual(fresh.buttons, config.buttons)
        XCTAssertEqual(fresh.apps, config.apps)
        XCTAssertTrue(fresh.general.lockPointerDuringDrag)
    }

    /// The point of the whole projection: a kill switch flipped on this Mac must survive settings
    /// arriving from another one, so sync can never reach across and turn the engine off.
    func testMachineLocalFieldsSurviveRemoteApply() throws {
        var local = LeiosConfig()
        local.general.scrollingEnabled = false
        local.general.buttonsEnabled = false
        local.general.showMenuBarItem = true
        local.scroll.speed = .low

        var remoteSource = LeiosConfig()
        remoteSource.scroll.speed = .high
        remoteSource.buttons = [:]
        let data = try SyncedConfig.encode(SyncedConfig(remoteSource))
        let remote = try SyncedConfig.decode(data)
        remote.apply(to: &local)

        XCTAssertFalse(local.general.scrollingEnabled)
        XCTAssertFalse(local.general.buttonsEnabled)
        XCTAssertTrue(local.general.showMenuBarItem)
        XCTAssertEqual(local.scroll.speed, .high)
        XCTAssertTrue(local.buttons.isEmpty)
    }

    func testMachineLocalFieldsAreNotEmitted() throws {
        var config = LeiosConfig()
        config.general.scrollingEnabled = false
        config.general.showMenuBarItem = true
        let data = try SyncedConfig.encode(SyncedConfig(config))
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertFalse(json.contains("scrollingEnabled"))
        XCTAssertFalse(json.contains("buttonsEnabled"))
        XCTAssertFalse(json.contains("showMenuBarItem"))
        XCTAssertTrue(json.contains("lockPointerDuringDrag"))
    }

    /// `LeiosConfig` reads a missing `buttons` key as the defaults. The payload must not: a peer
    /// that omitted the key would otherwise reset every Mac's mappings.
    func testMissingButtonsKeyLeavesLocalButtonsUntouched() throws {
        var local = LeiosConfig()
        local.buttons = [7: ButtonMapping(click: .middleClick)]

        let remote = try SyncedConfig.decode(Data(#"{"scroll":{"speed":"low"}}"#.utf8))
        XCTAssertNil(remote.buttons)
        remote.apply(to: &local)

        XCTAssertEqual(local.buttons, [7: ButtonMapping(click: .middleClick)])
        XCTAssertEqual(local.scroll.speed, .low)
    }

    /// The other half of that asymmetry: an empty object is a real edit, not a missing key.
    func testEmptyButtonsObjectClearsButtons() throws {
        var local = LeiosConfig()
        local.buttons = [7: ButtonMapping(click: .middleClick)]
        let remote = try SyncedConfig.decode(Data(#"{"buttons":{}}"#.utf8))
        remote.apply(to: &local)
        XCTAssertTrue(local.buttons.isEmpty)
    }

    func testOutboundPayloadAlwaysCarriesEverySection() {
        let payload = SyncedConfig(LeiosConfig())
        XCTAssertNotNil(payload.scroll)
        XCTAssertNotNil(payload.buttons)
        XCTAssertNotNil(payload.general)
        XCTAssertNotNil(payload.apps)
    }

    func testInvalidButtonKeysAreDroppedFromPayload() throws {
        let json = #"{"buttons":{"abc":{},"99":{},"5":{"drag":"twoFingerSwipe"}}}"#
        let decoded = try SyncedConfig.decode(Data(json.utf8))
        XCTAssertEqual(decoded.buttons?.keys.sorted(), [5])
    }

    func testEmptyBundleIdentifierIsDroppedFromPayload() throws {
        let json = #"{"apps":{"":{"name":"Nothing"},"com.apple.Safari":{"name":"Safari"}}}"#
        let decoded = try SyncedConfig.decode(Data(json.utf8))
        XCTAssertEqual(decoded.apps?.keys.sorted(), ["com.apple.Safari"])
    }

    /// `Action` has no case for unknown payloads, so a config written by a newer Leios throws.
    /// The sync layer relies on that to refuse the merge rather than silently dropping the action.
    func testUnknownActionPayloadFailsToDecode() {
        let json = #"{"buttons":{"4":{"click":{"teleport":{}}}}}"#
        XCTAssertThrowsError(try SyncedConfig.decode(Data(json.utf8)))
    }

    /// Two configurations that differ only in machine-local fields project equal, which is what
    /// stops a kill-switch flip from producing a CloudKit write and a spurious "last writer".
    func testProjectionEqualityIgnoresMachineLocalFields() {
        var a = LeiosConfig()
        var b = LeiosConfig()
        b.general.scrollingEnabled = false
        b.general.buttonsEnabled = false
        b.general.showMenuBarItem = true
        XCTAssertEqual(SyncedConfig(a), SyncedConfig(b))

        a.general.lockPointerDuringDrag = true
        XCTAssertNotEqual(SyncedConfig(a), SyncedConfig(b))
    }
}
