import XCTest
@testable import MousePilotShared

final class ScrollOverridesTests: XCTestCase {

    func testNilFieldsFollowGlobal() {
        var global = ScrollSettings()
        global.speed = .low
        global.smoothness = .regular
        var overrides = ScrollOverrides()
        overrides.speed = .high

        let resolved = overrides.resolved(against: global)
        XCTAssertEqual(resolved.speed, .high)       // pinned
        XCTAssertEqual(resolved.smoothness, .regular) // still following global
        XCTAssertEqual(resolved.modifiers, global.modifiers)
    }

    func testEmptyOverridesResolveToGlobal() {
        var global = ScrollSettings()
        global.precise = true
        XCTAssertTrue(ScrollOverrides().isEmpty)
        XCTAssertEqual(ScrollOverrides().resolved(against: global), global)
    }

    /// The engine skips the app lookup entirely when this map is empty, so a profile that resolves
    /// back to the global settings must not appear in it.
    func testEffectiveAppScrollDropsProfilesEqualToGlobal() {
        var config = MousePilotConfig()
        config.apps["com.apple.Safari"] = AppProfile(name: "Safari")
        XCTAssertTrue(config.effectiveAppScroll.isEmpty)

        // Pinning a field to the value it already had is not a difference either.
        config.apps["com.apple.Safari"]?.scroll.speed = config.scroll.speed
        XCTAssertTrue(config.effectiveAppScroll.isEmpty)

        config.apps["com.apple.Safari"]?.scroll.speed = .low
        XCTAssertEqual(config.effectiveAppScroll["com.apple.Safari"]?.speed, .low)
    }

    func testModifiesScrollByDefault() {
        var settings = ScrollSettings()
        settings.smoothness = .off
        settings.speed = .system
        settings.reverseDirection = false
        XCTAssertFalse(settings.modifiesScrollByDefault)

        // Neither of these can modify scrolling on its own: precise only feeds the acceleration
        // curve, which is dropped at speed == .system, and trackpadSimulation only matters at .high.
        var precise = settings
        precise.precise = true
        XCTAssertFalse(precise.modifiesScrollByDefault)
        var trackpad = settings
        trackpad.trackpadSimulation = true
        XCTAssertFalse(trackpad.modifiesScrollByDefault)

        for change in [{ (s: inout ScrollSettings) in s.smoothness = .regular },
                       { s in s.speed = .high },
                       { s in s.reverseDirection = true }] {
            var modified = settings
            change(&modified)
            XCTAssertTrue(modified.modifiesScrollByDefault)
        }
    }

    /// One profile that modifies scrolling has to arm the tap for the whole system, because the tap
    /// is created before the app under the pointer is known.
    func testGatingCoversProfiles() {
        var config = MousePilotConfig()
        config.scroll.smoothness = .off
        config.scroll.speed = .system
        config.scroll.reverseDirection = false
        XCTAssertFalse(config.scrollGating.modifiesByDefault)

        config.apps["com.apple.Safari"] = AppProfile(name: "Safari")
        config.apps["com.apple.Safari"]?.scroll.smoothness = .high
        XCTAssertTrue(config.scrollGating.modifiesByDefault)
    }

    func testGatingDedupesModifierMaps() {
        var config = MousePilotConfig()
        config.apps["a"] = AppProfile()
        config.apps["a"]?.scroll.speed = .low          // differs, but uses the global modifier map
        config.apps["b"] = AppProfile()
        config.apps["b"]?.scroll.modifiers = ScrollModifierFlags()
        config.apps["b"]?.scroll.modifiers?.zoom = 0   // a genuinely different map

        let maps = config.scrollGating.modifierMaps
        XCTAssertEqual(maps.count, 2)
        XCTAssertTrue(maps.contains(config.scroll.modifiers))
        XCTAssertTrue(maps.contains { $0.zoom == 0 })
    }
}
