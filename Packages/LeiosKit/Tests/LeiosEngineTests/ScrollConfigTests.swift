import XCTest
@testable import LeiosEngine
@testable import LeiosShared

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

    /// Per-app profiles get their own resolver, so one app's settings can't leak into another's.
    func testResolversAreIndependentPerApp() {
        let smooth = resolver(smoothness: .high, speed: .medium)
        let plain = resolver(smoothness: .off, speed: .system)
        XCTAssertEqual(smooth.base.animationCurve, .highInertiaPlusTrackpadSim)
        XCTAssertEqual(plain.base.animationCurve, .none)
        XCTAssertTrue(plain.base.isNoOp || plain.base.invertDirection == -1)
    }

    /// `settingsChanged` re-runs `update` on every surviving profile resolver on any config change,
    /// so an unchanged profile must keep its warm cache rather than rebuild every curve.
    func testNoOpUpdateKeepsCache() {
        let r = resolver(smoothness: .high, speed: .medium)
        let mods = ScrollModificationResult(inputMod: .none, effectMod: .zoom)
        let first = r.resolve(modifiers: mods, inputAxis: .vertical, display: CGMainDisplayID())
        r.update(settings: r.settings)
        XCTAssertTrue(first === r.resolve(modifiers: mods, inputAxis: .vertical, display: CGMainDisplayID()))
    }

    /// Settings that reproduce the incoming event exactly let the engine pass it through untouched
    /// instead of swallowing and re-synthesizing it.
    func testIsNoOp() {
        var s = ScrollSettings()
        s.smoothness = .off
        s.speed = .system
        s.reverseDirection = false
        XCTAssertTrue(ScrollConfigResolver(settings: s).base.isNoOp)
        var reversed = s
        reversed.reverseDirection = true
        XCTAssertFalse(ScrollConfigResolver(settings: reversed).base.isNoOp)
        var smooth = s
        smooth.smoothness = .high
        XCTAssertFalse(ScrollConfigResolver(settings: smooth).base.isNoOp)
    }

    func testScrollModifiersFromFlags() {
        let s = ScrollModifierFlags()
        XCTAssertEqual(ScrollModifiers.modifications(forFlags: LeiosConstants.ModifierFlag.shift, settings: s).effectMod, .horizontalScroll)
        XCTAssertEqual(ScrollModifiers.modifications(forFlags: LeiosConstants.ModifierFlag.command, settings: s).effectMod, .zoom)
        XCTAssertEqual(ScrollModifiers.modifications(forFlags: LeiosConstants.ModifierFlag.control, settings: s).inputMod, .quick)
        XCTAssertEqual(ScrollModifiers.modifications(forFlags: LeiosConstants.ModifierFlag.option, settings: s).inputMod, .precise)
        XCTAssertTrue(ScrollModifiers.modifications(forFlags: 0, settings: s).isEmpty)
        var none = s; none.zoom = 0
        XCTAssertTrue(ScrollModifiers.modifications(forFlags: LeiosConstants.ModifierFlag.command, settings: none).isEmpty)
    }
}
