import XCTest
@testable import MousePilotShared

final class ConfigCodableTests: XCTestCase {

    func testRoundTrip() throws {
        var config = MousePilotConfig()
        config.scroll.smoothness = .regular
        config.scroll.modifiers.zoom = 0
        config.buttons[7] = ButtonMapping(click: .navigateBack, hold: .symbolicHotkey(.missionControl), drag: .twoFingerSwipe)
        let data = try ConfigFile.encode(config)
        let decoded = try ConfigFile.decode(data)
        XCTAssertEqual(decoded, config)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try ConfigFile.decode(Data("{}".utf8))
        XCTAssertEqual(decoded, MousePilotConfig())
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

    func testInvalidButtonKeysAreDropped() throws {
        let json = #"{"buttons":{"abc":{},"99":{},"5":{"drag":"twoFingerSwipe"}}}"#
        let decoded = try ConfigFile.decode(Data(json.utf8))
        XCTAssertEqual(decoded.buttons.keys.sorted(), [5])
    }
}
