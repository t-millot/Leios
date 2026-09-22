import XCTest
@testable import LeiosShared

final class ScrollSpeedTests: XCTestCase {

    private func json(_ settings: ScrollSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A slider left on a preset writes exactly what a Leios from before the slider wrote.
    func testPresetsWriteTheOldFormat() throws {
        for (level, preset) in [(0.0, "low"), (0.5, "medium"), (1.0, "high")] {
            var settings = ScrollSettings()
            settings.scrollSpeed = ScrollSpeed(level: level)
            let written = try json(settings)
            XCTAssertEqual(written["speed"] as? String, preset)
            XCTAssertNil(written["speedLevel"])
        }
    }

    /// Between presets, `speed` holds the nearest one — all an older Leios reads, and it must be a
    /// value that build knows — and the exact position travels beside it.
    func testInBetweenStoresTheNearestPresetAndTheExactLevel() throws {
        for (level, preset) in [(0.2, "low"), (0.3, "medium"), (0.7, "medium"), (0.8, "high")] {
            var settings = ScrollSettings()
            settings.scrollSpeed = ScrollSpeed(level: level)
            let written = try json(settings)
            XCTAssertEqual(written["speed"] as? String, preset)
            XCTAssertEqual(written["speedLevel"] as? Double, level)
            let read = try JSONDecoder().decode(ScrollSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(read.scrollSpeed, ScrollSpeed(level: level))
        }
    }

    func testAFileFromBeforeTheSliderReadsItsPreset() throws {
        let low = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"speed":"low"}"#.utf8))
        XCTAssertEqual(low.scrollSpeed, ScrollSpeed(level: 0))
        let system = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"speed":"system"}"#.utf8))
        XCTAssertEqual(system.scrollSpeed, ScrollSpeed(usesSystem: true, level: ScrollSpeed.defaultLevel))
    }

    func testMacOSSpeedKeepsTheSliderWhereItWas() {
        var settings = ScrollSettings()
        settings.scrollSpeed = ScrollSpeed(level: 0.3)
        settings.scrollSpeed.usesSystem = true
        XCTAssertEqual(settings.speed, .system)
        XCTAssertEqual(settings.scrollSpeed.level, 0.3)
        settings.scrollSpeed.usesSystem = false
        XCTAssertEqual(settings.scrollSpeed, ScrollSpeed(level: 0.3))
    }

    func testLevelsAreClampedAndRounded() throws {
        let high = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"speed":"high","speedLevel":7}"#.utf8))
        XCTAssertEqual(high.scrollSpeed.level, 1)
        let low = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"speed":"low","speedLevel":-2}"#.utf8))
        XCTAssertEqual(low.scrollSpeed.level, 0)
        XCTAssertEqual(ScrollSpeed(level: .nan).level, ScrollSpeed.defaultLevel)
        var speed = ScrollSpeed(level: 0.5)
        speed.level = 0.1 * 3 // what a slider stepping by 0.1 produces
        XCTAssertEqual(speed.level, 0.3)
    }

    /// `speed` is still written directly in places, and that must not leave a stale finer position.
    func testWritingThePresetDropsTheFinerPosition() {
        var settings = ScrollSettings()
        settings.scrollSpeed = ScrollSpeed(level: 0.7)
        settings.speed = .low
        XCTAssertEqual(settings.scrollSpeed, ScrollSpeed(level: 0))
    }

    /// A profile pins Speed as a whole: pinned to a preset, it must not pick up the global slider.
    func testProfilesPinSpeedAsAWhole() {
        var global = ScrollSettings()
        global.scrollSpeed = ScrollSpeed(level: 0.7)

        var app = ScrollOverrides()
        XCTAssertEqual(app.resolved(against: global).scrollSpeed.level, 0.7)

        app.speed = .low // how a profile saved before the slider reads
        XCTAssertEqual(app.resolved(against: global).scrollSpeed, ScrollSpeed(level: 0))

        app.scrollSpeed = ScrollSpeed(level: 0.2)
        XCTAssertEqual(app.resolved(against: global).scrollSpeed, ScrollSpeed(level: 0.2))

        app.scrollSpeed = nil
        XCTAssertTrue(app.isEmpty)
        XCTAssertEqual(app.resolved(against: global).scrollSpeed.level, 0.7)
    }
}
