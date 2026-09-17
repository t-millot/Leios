// HybridCurve.swift
// MousePilot Engine — a base curve (Bezier or line) followed by a DragCurve for natural deceleration.
// Ports Shared/Math/Curves/HybridCurves.swift (BezierHybridCurve, LineHybridCurve). Derived from Mac Mouse Fix, MMF License.

import Foundation

enum HybridSubCurve {
    case none, base, drag
}

class HybridCurve: Curve {

    var baseCurve: Curve { fatalError("subclass") }

    fileprivate(set) var baseTimeInterval: Interval = .unitInterval
    fileprivate(set) var baseDistanceInterval: Interval = .unitInterval
    var baseDuration: Double { baseTimeInterval.length }
    var baseDistance: Double { baseDistanceInterval.length }

    fileprivate var dragCoefficient: Double = -1
    fileprivate var dragExponent: Double = -1
    fileprivate var stopSpeed: Double = -1
    fileprivate(set) var dragCurve: DragCurve?

    fileprivate var dragTimeRange: Double { dragCurve?.timeInterval.length ?? 0 }
    var dragValueRange: Double { dragCurve?.distanceInterval.length ?? 0 }

    var duration: Double { baseDuration + dragTimeRange }
    var distance: Double { baseDistance + dragValueRange }

    fileprivate static func getDragCurve(initialSpeed: Double, stopSpeed: Double, coefficient: Double, exponent: Double) -> DragCurve? {
        if initialSpeed > stopSpeed {
            return DragCurve(coefficient: coefficient, exponent: exponent, initialSpeed: initialSpeed, stopSpeed: stopSpeed)
        }
        return nil
    }

    override func evaluate(at x: Double) -> Double {
        let baseFraction = duration > 0 ? baseDuration / duration : 1
        if baseDuration > 0 && x <= baseFraction {
            var baseCurveResult = baseCurve.evaluate(at: Math.scale(value: x, from: baseTimeIntervalUnit, to: .unitInterval, allowOutOfBounds: true))
            if baseCurveResult > 1 { baseCurveResult = 1 }
            return Math.scale(value: baseCurveResult, from: .unitInterval, to: baseDistanceIntervalUnit, allowOutOfBounds: true)
        } else if let c = dragCurve, dragTimeRange > 0 {
            let dragCurveResult = c.evaluate(at: Math.scale(value: x, from: dragTimeIntervalUnit, to: .unitInterval, allowOutOfBounds: true))
            return Math.scale(value: dragCurveResult, from: .unitInterval, to: dragDistanceIntervalUnit, allowOutOfBounds: true)
        } else {
            Log.engine.warning("HybridCurve evaluated past its base curve without a drag curve (x: \(x))")
            return x
        }
    }

    private var baseTimeIntervalUnit: Interval { Interval(start: 0, end: baseDuration / duration) }
    private var baseDistanceIntervalUnit: Interval { Interval(start: 0, end: baseDistance / distance) }
    private var dragTimeIntervalUnit: Interval { Interval(start: baseDuration / duration, end: 1) }
    private var dragDistanceIntervalUnit: Interval { Interval(start: baseDistance / distance, end: 1) }

    func subCurve(at x: Double) -> HybridSubCurve {
        (baseDuration > 0 && x <= baseDuration / duration) ? .base : .drag
    }
}

// MARK: - BezierHybridCurve

final class BezierHybridCurve: HybridCurve {

    private let _baseCurve: Bezier
    override var baseCurve: Curve { _baseCurve }

    init(baseCurve: Bezier, minDuration: Double, distance targetDistance: Double, dragCoefficient: Double, dragExponent: Double, stopSpeed: Double, distanceEpsilon: Double) {
        _baseCurve = baseCurve
        super.init()

        assert(targetDistance > 0)
        assert(baseCurve.controlPoints.first == Vector(x: 0, y: 0))
        assert(baseCurve.controlPoints.last == Vector(x: 1, y: 1))

        let transitionTime: Double
        let transitionDistance: Double
        let dragCurve: DragCurve?
        if baseCurve.isLine {
            (transitionTime, transitionDistance, dragCurve) = LineHybridCurve._lineInit(minDuration: minDuration, distance: targetDistance, dragCoefficient: dragCoefficient, dragExponent: dragExponent, stopSpeed: stopSpeed)
        } else {
            (transitionTime, transitionDistance, dragCurve) = BezierHybridCurve._bezierInit(baseCurve: baseCurve, minDuration: minDuration, targetDistance: targetDistance, dragCoefficient: dragCoefficient, dragExponent: dragExponent, stopSpeed: stopSpeed, distanceEpsilon: distanceEpsilon)
        }

        baseTimeInterval = Interval(start: 0, end: transitionTime)
        baseDistanceInterval = Interval(start: 0, end: transitionDistance)
        self.dragCurve = dragCurve
        self.dragCoefficient = dragCoefficient
        self.dragExponent = dragExponent
        self.stopSpeed = stopSpeed
    }

    private static func combinedDistance(transitionPoint t: Double, baseCurve: Bezier, baseDistance: Double, baseDuration: Double, dragExponent: Double, dragCoefficient: Double, stopSpeed: Double) -> Double {
        assert(0 <= t && t <= 1)
        let slopeAtT = baseCurve.derivativeDyOverDx(atT: t)
        let speedAtT = slopeAtT * baseDistance / baseDuration
        let transitionDistance = baseCurve.sampleCurve(onAxis: .vertical, atT: t) * baseDistance
        if speedAtT <= stopSpeed {
            return transitionDistance
        }
        let dragCurve = DragCurve(coefficient: dragCoefficient, exponent: dragExponent, initialSpeed: speedAtT, stopSpeed: stopSpeed)
        return transitionDistance + dragCurve.distanceInterval.length
    }

    static func _bezierInit(baseCurve: Bezier, minDuration: Double, targetDistance: Double, dragCoefficient: Double, dragExponent: Double, stopSpeed: Double, distanceEpsilon: Double) -> (transitionTime: Double, transitionDistance: Double, dragCurve: DragCurve?) {

        assert(baseCurve.defaultEpsilon < Bezier.defaultDefaultEpsilon)

        var transitionPointRange: Interval?
        var transitionPoint: Double?
        var dragCurve: DragCurve?

        // Scan t from 1.0 down to 0.0 in steps of 1/n to bracket the transition point.
        let n = 10
        for k in 0...n {
            let t = Math.scale(value: Double(k), from: Interval(0, Double(n)), to: .reversedUnitInterval)
            let combined = combinedDistance(transitionPoint: t, baseCurve: baseCurve, baseDistance: targetDistance, baseDuration: minDuration, dragExponent: dragExponent, dragCoefficient: dragCoefficient, stopSpeed: stopSpeed)
            if abs(combined - targetDistance) < distanceEpsilon {
                transitionPoint = t
                break
            }
            if combined <= targetDistance {
                transitionPointRange = Interval(t, t + (1 / Double(n)))
                break
            }
        }

        if let range = transitionPointRange {
            transitionPoint = Math.bisect(searchRange: range, targetOutput: targetDistance, epsilon: distanceEpsilon) { t in
                combinedDistance(transitionPoint: t, baseCurve: baseCurve, baseDistance: targetDistance, baseDuration: minDuration, dragExponent: dragExponent, dragCoefficient: dragCoefficient, stopSpeed: stopSpeed)
            }
        }

        if transitionPoint == nil {
            // Fallback: a drag curve that exactly covers the target distance; the base curve is ignored.
            dragCurve = DragCurve(coefficient: dragCoefficient, exponent: dragExponent, distance: targetDistance, stopSpeed: stopSpeed)
            transitionPoint = 0
        } else {
            let transitionSpeed = baseCurve.derivativeDyOverDx(atT: transitionPoint!) * targetDistance / minDuration
            if transitionSpeed > stopSpeed {
                dragCurve = DragCurve(coefficient: dragCoefficient, exponent: dragExponent, initialSpeed: transitionSpeed, stopSpeed: stopSpeed)
            } else {
                transitionPoint = 1
            }
        }

        let tp = transitionPoint!
        let transitionTime = baseCurve.sampleCurve(onAxis: .horizontal, atT: tp) * minDuration
        let transitionDistance = baseCurve.sampleCurve(onAxis: .vertical, atT: tp) * targetDistance
        return (transitionTime, transitionDistance, dragCurve)
    }
}

// MARK: - LineHybridCurve

final class LineHybridCurve: HybridCurve {

    static let _baseCurve = Line(a: 1, b: 0)
    override var baseCurve: Curve { LineHybridCurve._baseCurve }

    init(minDuration: Double, distance: Double, dragCoefficient: Double, dragExponent: Double, stopSpeed: Double) {
        super.init()
        assert(distance > 0)
        let (transitionTime, transitionDistance, dragCurve) = LineHybridCurve._lineInit(minDuration: minDuration, distance: distance, dragCoefficient: dragCoefficient, dragExponent: dragExponent, stopSpeed: stopSpeed)
        baseTimeInterval = Interval(start: 0, end: transitionTime)
        baseDistanceInterval = Interval(start: 0, end: transitionDistance)
        self.dragCurve = dragCurve
        self.dragCoefficient = dragCoefficient
        self.dragExponent = dragExponent
        self.stopSpeed = stopSpeed
    }

    static func _lineInit(minDuration: Double, distance: Double, dragCoefficient: Double, dragExponent: Double, stopSpeed: Double) -> (transitionTime: Double, transitionDistance: Double, dragCurve: DragCurve?) {
        let transitionSpeed = LineHybridCurve._baseCurve.slope * distance / minDuration
        if transitionSpeed <= stopSpeed {
            return (minDuration, distance, nil)
        }
        guard var dragCurve = getDragCurve(initialSpeed: transitionSpeed, stopSpeed: stopSpeed, coefficient: dragCoefficient, exponent: dragExponent) else {
            assertionFailure()
            return (minDuration, distance, nil)
        }
        var transitionDistance = distance - dragCurve.distanceInterval.length
        if transitionDistance < 0 {
            // The drag curve alone covers more than the whole distance: use a distance-based drag curve and ignore the line.
            dragCurve = DragCurve(coefficient: dragCoefficient, exponent: dragExponent, distance: distance, stopSpeed: stopSpeed)
            transitionDistance = 0
        }
        let transitionTime = LineHybridCurve._baseCurve.evaluate(atY: transitionDistance / distance) * minDuration
        return (transitionTime, transitionDistance, dragCurve)
    }
}
