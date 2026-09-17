import XCTest
@testable import MousePilotEngine
@testable import MousePilotShared

final class RemapTableTests: XCTestCase {

    func testMaxLevelAndLandscape() {
        let table = RemapTable(buttons: [
            3: ButtonMapping(click: .symbolicHotkey(.lookUp), doubleClick: .symbolicHotkey(.launchpad), hold: .symbolicHotkey(.showDesktop), drag: .threeFingerSwipe),
            4: ButtonMapping(click: .navigateBack),
            5: ButtonMapping(drag: .twoFingerSwipe),
            6: ButtonMapping(),
        ])
        XCTAssertTrue(table.anyButtonMapped)
        XCTAssertTrue(table.anyDragMapped)
        XCTAssertEqual(table.maxLevel(button: 3), 2)
        XCTAssertEqual(table.maxLevel(button: 4), 1)
        XCTAssertEqual(table.maxLevel(button: 5), 1)
        XCTAssertEqual(table.maxLevel(button: 6), 0)
        XCTAssertEqual(table.maxLevel(button: 7), 0)

        let mods = table.modifications(for: ModifierState())
        let l3 = table.assessMappingLandscape(button: 3, level: 1, modifications: mods)
        XCTAssertTrue(l3.clickExists); XCTAssertTrue(l3.downStateEffectExists); XCTAssertTrue(l3.greaterLevelExists)
        let l3b = table.assessMappingLandscape(button: 3, level: 2, modifications: mods)
        XCTAssertTrue(l3b.clickExists); XCTAssertFalse(l3b.downStateEffectExists); XCTAssertFalse(l3b.greaterLevelExists)
        let l4 = table.assessMappingLandscape(button: 4, level: 1, modifications: mods)
        XCTAssertTrue(l4.clickExists); XCTAssertFalse(l4.downStateEffectExists); XCTAssertFalse(l4.greaterLevelExists)
        let l5 = table.assessMappingLandscape(button: 5, level: 1, modifications: mods)
        XCTAssertFalse(l5.clickExists); XCTAssertTrue(l5.downStateEffectExists)
        XCTAssertEqual(mods.action(button: 3, level: 2, duration: .click), .symbolicHotkey(.launchpad))
        XCTAssertEqual(mods.action(button: 3, level: 1, duration: .hold), .symbolicHotkey(.showDesktop))
    }

    func testDragArming() {
        let table = RemapTable(buttons: [
            4: ButtonMapping(drag: .threeFingerSwipe),
            5: ButtonMapping(drag: .twoFingerSwipe),
        ])
        XCTAssertNil(table.dragArmed(for: ModifierState()))
        XCTAssertEqual(table.dragArmed(for: ModifierState(keyboardFlags: 0, buttons: [ButtonModifier(button: 4, level: 1)])), .threeFingerSwipe)
        XCTAssertNil(table.dragArmed(for: ModifierState(keyboardFlags: 0, buttons: [ButtonModifier(button: 4, level: 2)])))
        // Most recently pressed wins on ties.
        XCTAssertEqual(table.dragArmed(for: ModifierState(keyboardFlags: 0, buttons: [ButtonModifier(button: 4, level: 1), ButtonModifier(button: 5, level: 1)])), .twoFingerSwipe)
        XCTAssertEqual(table.dragArmed(for: ModifierState(keyboardFlags: MPConstants.ModifierFlag.shift, buttons: [ButtonModifier(button: 4, level: 1)])), .threeFingerSwipe, "extra keyboard flags don't block a button-only precondition")
    }
}
