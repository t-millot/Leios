import XCTest
import CoreGraphics
import LeiosShared
@testable import LeiosEngine

/// On High, each wheel tick that arrives while the content is still moving starts at that speed
/// instead of jumping to its own. These pin the curve's shape; how much smoothing feels right was
/// tuned against the real animator — see the `.highInertia` entry in `ScrollConfig`.
final class SpeedSmoothingTests: XCTestCase {

    private func config(_ smoothness: ScrollSettings.Smoothness, trackpadSimulation: Bool = true) -> ScrollConfig {
        var settings = ScrollSettings()
        settings.smoothness = smoothness
        settings.trackpadSimulation = trackpadSimulation
        return ScrollConfig(settings: settings)
    }

    /// Points per second at unit time `x`, by finite difference. The step stays well above the
    /// Bezier solver's 1e-4 tolerance, which would otherwise swamp it.
    private func speed(_ curve: Curve, at x: Double, distance: Double, duration: Double) -> Double {
        let h = 1e-3
        let lo = max(x - h, 0)
        let hi = min(x + h, 1)
        return (curve.evaluate(at: hi) - curve.evaluate(at: lo)) / (hi - lo) * distance / duration
    }

    func testHighStartsARunningTickAtTheCurrentSpeed() throws {
        let distance = 100.0
        for trackpadSimulation in [true, false] {
            let high = try XCTUnwrap(ScrollController.tickAnimation(distance: distance, currentSpeed: 120, timeBetweenTicks: 0.3, config: config(.high, trackpadSimulation: trackpadSimulation)))
            XCTAssertEqual(speed(high.curve, at: 0, distance: distance, duration: high.duration), 120, accuracy: 8)
            XCTAssertEqual(high.curve.evaluate(at: 1), 1, accuracy: 1e-3, "a smoothed tick must still cover its whole distance")
        }

        // Regular sets off at the tick's own speed: the distance over its 180 ms base for a slow tick.
        let regular = try XCTUnwrap(ScrollController.tickAnimation(distance: distance, currentSpeed: 120, timeBetweenTicks: 0.3, config: config(.regular)))
        XCTAssertEqual(speed(regular.curve, at: 0, distance: distance, duration: regular.duration), distance / 0.18, accuracy: 10)
    }

    /// From a standstill there is no motion to blend into: the tick must answer the wheel at once,
    /// at its own speed, straight through the base part.
    func testTickFromAStandstillIsAStraightLine() throws {
        let distance = 90.0
        let tick = try XCTUnwrap(ScrollController.tickAnimation(distance: distance, currentSpeed: 0, timeBetweenTicks: .greatestFiniteMagnitude, config: config(.high)))
        let hc = try XCTUnwrap(tick.curve as? HybridCurve)
        let handOver = hc.baseDuration / hc.duration
        for x in [0, handOver / 2, handOver * 0.9] {
            XCTAssertEqual(speed(tick.curve, at: x, distance: distance, duration: tick.duration), distance / 0.22, accuracy: 5)
        }
    }

    func testOnlyHighSmoothsSpeed() {
        XCTAssertGreaterThan(config(.high, trackpadSimulation: true).animationCurveParams!.speedSmoothing, 0)
        XCTAssertGreaterThan(config(.high, trackpadSimulation: false).animationCurveParams!.speedSmoothing, 0)
        XCTAssertEqual(config(.regular).animationCurveParams!.speedSmoothing, 0)
        XCTAssertNil(config(.off).animationCurveParams)

        // A modifier's curve keeps its fixed shape: quick scroll throws a page, precise scroll moves
        // a few points, and zoom is not scrolling at all. Horizontal scrolling keeps High's curve.
        let resolver = ScrollConfigResolver(settings: ScrollSettings())
        func smoothing(_ input: ScrollInputModification, _ effect: ScrollEffectModification) -> Double {
            resolver.resolve(modifiers: ScrollModificationResult(inputMod: input, effectMod: effect), inputAxis: .vertical, display: CGMainDisplayID()).animationCurveParams!.speedSmoothing
        }
        XCTAssertGreaterThan(smoothing(.none, .horizontalScroll), 0)
        XCTAssertEqual(smoothing(.quick, .none), 0)
        XCTAssertEqual(smoothing(.precise, .none), 0)
        XCTAssertEqual(smoothing(.none, .zoom), 0)
    }

    /// A base curve that is not a straight line has to start at its own slope and hand over to the
    /// glide at the speed it had reached. Mac Mouse Fix stretched the whole base curve over the part
    /// that runs before the hand-over, which for anything but a line started at the wrong speed and
    /// jumped when the glide took over — invisible while every base curve it shipped was a line.
    func testCurvedBaseHandsOverToTheGlideWithoutAJump() {
        let distance = 100.0
        let baseDuration = 0.22
        let startSlope = 0.25
        let base = ScrollController.speedMatchingCurve(startSlope: startSlope, ramp: 0.2)
        let hc = BezierHybridCurve(baseCurve: base, minDuration: baseDuration, distance: distance, dragCoefficient: 40, dragExponent: 0.7, stopSpeed: 30, distanceEpsilon: 0.2)
        XCTAssertNotNil(hc.dragCurve)
        XCTAssertEqual(hc.evaluate(at: 1), 1, accuracy: 1e-3)

        XCTAssertEqual(speed(hc, at: 0, distance: distance, duration: hc.duration), startSlope * distance / baseDuration, accuracy: 6)

        let handOver = hc.baseDuration / hc.duration
        let before = speed(hc, at: handOver - 2e-3, distance: distance, duration: hc.duration)
        let after = speed(hc, at: handOver + 2e-3, distance: distance, duration: hc.duration)
        XCTAssertEqual(after / before, 1, accuracy: 0.03, "speed jumps from \(before) to \(after) pt/s where the glide takes over")
    }
}
