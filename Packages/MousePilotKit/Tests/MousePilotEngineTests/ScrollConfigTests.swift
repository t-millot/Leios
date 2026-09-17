import XCTest
@testable import MousePilotEngine
@testable import MousePilotShared

final class ScrollConfigTests: XCTestCase {

    private func resolver(smoothness: ScrollSettings.Smoothness, speed: ScrollSettings.Speed, precise: Bool = false, trackpadSim: Bool = true) -> ScrollConfigResolver {
        var s = ScrollSettings()
        s.smoothness = smoothness
        s.speed = speed
        s.precise = precise
        s.trackpadSimulation = trackpadSim
        return ScrollConfigResolver(settings: s)
    }

    func testCurveNameMapping() {
        XCTAssertEqual(resolver(smoothness: .off, speed: .medium).base.animationCurve, .none)
        XCTAssertEqual(resolver(smoothness: .regular, speed: .medium).base.animationCurve, .lowInertia)
        XCTAssertEqual(resolver(smoothness: .high, speed: .medium).base.animationCurve, .highInertiaPlusTrackpadSim)
        XCTAssertEqual(resolver(smoothness: .high, speed: .medium, trackpadSim: false).base.animationCurve, .highInertia)
        XCTAssertFalse(resolver(smoothness: .off, speed: .medium).base.smoothEnabled)
    }

    func testAccelerationCurveEndpoints() {
        // Smoothness off, medium speed, 1080p display: minSens 30, maxSens 60 scaled to display.
        let r = resolver(smoothness: .off, speed: .medium)
        let cfg = r.resolve(modifiers: ScrollModificationResult(), inputAxis: .vertical, display: CGMainDisplayID())
        let curve = cfg.accelerationCurve!
        XCTAssertEqual(curve.evaluate(at: 1), 30, accuracy: 0.01)
        let screenH = Double(CGDisplayPixelsHigh(CGMainDisplayID()))
        let expectedMax = 60 * 0.9 + 60 * 0.1 * (screenH / 1080)
        XCTAssertEqual(curve.evaluate(at: 1 / 0.015), expectedMax, accuracy: 0.6)
        XCTAssertEqual(cfg.fastScrollCurve?.t, 6)
    }

    func testSystemSpeedUsesAppleAcceleration() {
        let r = resolver(smoothness: .high, speed: .system)
        let cfg = r.resolve(modifiers: ScrollModificationResult(), inputAxis: .vertical, display: CGMainDisplayID())
        XCTAssertTrue(cfg.useAppleAcceleration)
        let quick = r.resolve(modifiers: ScrollModificationResult(inputMod: .quick, effectMod: .none), inputAxis: .vertical, display: CGMainDisplayID())
        XCTAssertFalse(quick.useAppleAcceleration)
        XCTAssertEqual(quick.animationCurve, .quickScroll)
        XCTAssertEqual(quick.consecutiveScrollTickIntervalMax, 0.2, accuracy: 1e-9)
    }

    func testModifierOverrides() {
        let r = resolver(smoothness: .high, speed: .medium)
        let zoom = r.resolve(modifiers: ScrollModificationResult(inputMod: .none, effectMod: .zoom), inputAxis: .vertical, display: CGMainDisplayID())
        XCTAssertEqual(zoom.animationCurve, .touchDriver)
        XCTAssertFalse(zoom.animationCurveParams!.useDragCurve)
        let precise = r.resolve(modifiers: ScrollModificationResult(inputMod: .precise, effectMod: .none), inputAxis: .vertical, display: CGMainDisplayID())
        XCTAssertEqual(precise.animationCurve, .preciseScroll)
        XCTAssertNil(precise.fastScrollCurve)
        XCTAssertEqual(precise.accelerationCurve!.evaluate(at: 1), 1, accuracy: 0.01)
        // Precise mod never turns smoothing on.
        let offPrecise = resolver(smoothness: .off, speed: .medium).resolve(modifiers: ScrollModificationResult(inputMod: .precise, effectMod: .none), inputAxis: .vertical, display: CGMainDisplayID())
        XCTAssertEqual(offPrecise.animationCurve, .none)
        // Cached instance
        XCTAssertTrue(zoom === r.resolve(modifiers: ScrollModificationResult(inputMod: .none, effectMod: .zoom), inputAxis: .vertical, display: CGMainDisplayID()))
    }

    func testScrollModifiersFromFlags() {
        let s = ScrollModifierFlags()
        XCTAssertEqual(ScrollModifiers.modifications(forFlags: MPConstants.ModifierFlag.shift, settings: s).effectMod, .horizontalScroll)
        XCTAssertEqual(ScrollModifiers.modifications(forFlags: MPConstants.ModifierFlag.command, settings: s).effectMod, .zoom)
        XCTAssertEqual(ScrollModifiers.modifications(forFlags: MPConstants.ModifierFlag.control, settings: s).inputMod, .quick)
        XCTAssertEqual(ScrollModifiers.modifications(forFlags: MPConstants.ModifierFlag.option, settings: s).inputMod, .precise)
        XCTAssertTrue(ScrollModifiers.modifications(forFlags: 0, settings: s).isEmpty)
        var none = s; none.zoom = 0
        XCTAssertTrue(ScrollModifiers.modifications(forFlags: MPConstants.ModifierFlag.command, settings: none).isEmpty)
    }
}
