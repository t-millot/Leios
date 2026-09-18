import XCTest
@testable import LeiosEngine

final class CurveTests: XCTestCase {

    func testLinearBezierReducesToLine() {
        let b = Bezier(points: [(0, 0), (0, 0), (1, 1), (1, 1)], defaultEpsilon: 0.001)
        XCTAssertTrue(b.isLine)
        XCTAssertEqual(b.evaluate(at: 0.25), 0.25, accuracy: 1e-9)
        XCTAssertEqual(b.derivativeDyOverDx(atT: 0.5), 1, accuracy: 1e-9)
    }

    func testCubicBezierEndpointsAndMonotony() {
        let b = Bezier(points: [(0, 0), (0, 0), (0.5, 1), (1, 1)], defaultEpsilon: 0.001)
        XCTAssertFalse(b.isLine)
        XCTAssertEqual(b.evaluate(at: 0), 0, accuracy: 0.01)
        XCTAssertEqual(b.evaluate(at: 1), 1, accuracy: 0.01)
        var last = -1.0
        for i in 0...50 {
            let x = Double(i) / 50
            let y = b.evaluate(at: x)
            XCTAssertGreaterThanOrEqual(y, last - 1e-6, "not monotone at x=\(x)")
            last = y
        }
        XCTAssertGreaterThan(b.evaluate(at: 0.5), 0.5)
        XCTAssertEqual(b.exitSlope, 0, accuracy: 1e-9)
        XCTAssertEqual(b.entrySlope, 2.0, accuracy: 1e-9)
    }

    func testDragCurveSpeedInit() {
        for exponent in [0.7, 1.0, 2.0, 1.05] {
            let c = DragCurve(coefficient: 40, exponent: exponent, initialSpeed: 3000, stopSpeed: 30)
            XCTAssertTrue(c.timeInterval.length.isFinite && c.timeInterval.length > 0, "exp \(exponent)")
            XCTAssertTrue(c.distanceInterval.length.isFinite && c.distanceInterval.length > 0, "exp \(exponent)")
            XCTAssertEqual(c.evaluate(at: 0), 0, accuracy: 1e-6, "exp \(exponent)")
            XCTAssertEqual(c.evaluate(at: 1), 1, accuracy: 1e-6, "exp \(exponent)")
            XCTAssertLessThan(c.evaluate(at: 0.5), 1)
            XCTAssertGreaterThan(c.evaluate(at: 0.5), 0.5) // decelerating: more than half the distance in the first half
        }
    }

    func testDragCurveDistanceInit() {
        for exponent in [0.7, 1.0, 2.0] {
            let c = DragCurve(coefficient: 30, exponent: exponent, distance: 500, stopSpeed: 1)
            XCTAssertEqual(c.distanceInterval.length, 500, accuracy: 1e-6, "exp \(exponent)")
            XCTAssertEqual(c.evaluate(at: 1), 1, accuracy: 1e-6)
        }
    }

    func testBezierHybridCurveCoversTargetDistance() {
        let linear = Bezier(points: [(0, 0), (0, 0), (1, 1), (1, 1)], defaultEpsilon: 0.001)
        let cubic = Bezier(points: [(0, 0), (0, 0), (0.5, 1), (1, 1)], defaultEpsilon: 0.001)
        for base in [linear, cubic] {
            for target in [50.0, 200.0, 1000.0, 5000.0] {
                // High inertia params: exp 0.7, coeff 40, stop 30, 220 ms
                let hc = BezierHybridCurve(baseCurve: base, minDuration: 0.220, distance: target, dragCoefficient: 40, dragExponent: 0.7, stopSpeed: 30, distanceEpsilon: 0.2)
                XCTAssertEqual(hc.distance, target, accuracy: 0.5, "target \(target) line=\(base.isLine)")
                XCTAssertGreaterThanOrEqual(hc.duration, 0.220 - 1e-9)
                XCTAssertEqual(hc.evaluate(at: 0), 0, accuracy: 1e-6)
                XCTAssertEqual(hc.evaluate(at: 1), 1, accuracy: 1e-3)
                if hc.baseDuration > 0 { XCTAssertEqual(hc.subCurve(at: 0.01), .base) }
                if hc.dragValueRange > 0 { XCTAssertEqual(hc.subCurve(at: 0.999), .drag) }
                XCTAssertGreaterThan(hc.evaluate(at: 0.5), 0.5) // decelerating overall
                // Regular params: exp 1.0, coeff 23, stop 30
                let hc2 = BezierHybridCurve(baseCurve: base, minDuration: 0.15, distance: target, dragCoefficient: 23, dragExponent: 1.0, stopSpeed: 30, distanceEpsilon: 0.2)
                XCTAssertEqual(hc2.distance, target, accuracy: 0.5)
            }
        }
    }

    func testCappedAccelerationCurveShape() {
        let xMin = 1 / 0.160, xMax = 1 / 0.015
        let curve = BezierCappedAccelerationCurve(xMin: xMin, xMax: xMax, yMin: 60, yMax: 180, curvature: 0.0, defaultEpsilon: 0.05)
        XCTAssertEqual(curve.evaluate(at: 1), 60, accuracy: 1e-6)          // flat below xMin
        XCTAssertEqual(curve.evaluate(at: xMin), 60, accuracy: 0.5)
        XCTAssertEqual(curve.evaluate(at: xMax), 180, accuracy: 0.5)
        var last = 0.0
        for i in 0...40 {
            let x = xMin + (xMax - xMin) * Double(i) / 40
            let y = curve.evaluate(at: x)
            XCTAssertGreaterThanOrEqual(y, last - 1e-6)
            last = y
        }
        XCTAssertGreaterThan(curve.evaluate(at: xMax * 2), 180)             // linear extrapolation beyond xMax
        let curved = BezierCappedAccelerationCurve(xMin: xMin, xMax: xMax, yMin: 30, yMax: 120, curvature: 3.0, defaultEpsilon: 0.05)
        XCTAssertEqual(curved.controlPoints.count, 5)
        XCTAssertEqual(curved.evaluate(at: xMax), 120, accuracy: 0.5)
    }

    func testScrollSpeedupCurve() {
        let c = ScrollSpeedupCurve(swipeThreshold: 2, initialSpeedup: 1.33, exponentialSpeedup: 7.5)
        XCTAssertEqual(c.evaluate(at: 0), 1)
        XCTAssertEqual(c.evaluate(at: 1), 1)
        XCTAssertEqual(c.evaluate(at: 2), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(c.evaluate(at: 3), 1)
        XCTAssertGreaterThan(c.evaluate(at: 6), c.evaluate(at: 3))
    }

    func testCombinedLinearCurve() {
        let c = CombinedLinearCurve(yValues: [30, 60, 120])
        XCTAssertEqual(c.evaluate(atX: 0), 30)
        XCTAssertEqual(c.evaluate(atX: 0.5), 60)
        XCTAssertEqual(c.evaluate(atX: 1), 120)
        XCTAssertEqual(c.evaluate(atX: 0.25), 45)
    }

    func testMathScaleFlipsForOppositeDirections() {
        XCTAssertEqual(Math.scale(value: 0.25, from: .unitInterval, to: .reversedUnitInterval), 0.75)
        XCTAssertEqual(Math.scale(value: 5, from: Interval(0, 10), to: Interval(100, 200)), 150)
        XCTAssertEqual(Math.roundUp(0.1, toMultiple: 1.0 / 60.0), 7.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(Math.intCycle(x: 3, lower: 1, upper: 2), 2) // MMF's inclusive-bound quirk
        XCTAssertEqual(Math.intCycle(x: 1, lower: 1, upper: 2), 1)
    }
}
