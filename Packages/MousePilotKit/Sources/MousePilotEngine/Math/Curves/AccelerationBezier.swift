// AccelerationBezier.swift
// MousePilot Engine — Bezier that is flat before its first point and linearly extrapolated after its last.
// Ports Shared/Math/Curves/AccelerationBezier.swift. Derived from Mac Mouse Fix, MMF License.

import Foundation

class AccelerationBezier: Bezier {

    private(set) var preLine: Line
    private(set) var postLine: Line

    override init(controlPoints: [Vector], defaultEpsilon: Double = Bezier.defaultDefaultEpsilon) {
        preLine = Line(a: 0, b: 0)
        postLine = preLine
        super.init(controlPoints: controlPoints, defaultEpsilon: defaultEpsilon)

        // preLine: slope 0 through the first control point.
        preLine = Line(a: 0, b: controlPoints[0].y)
        // postLine: the exit slope through the last control point.
        let aPost = exitSlope
        let cLast = self.controlPoints[n]
        postLine = Line(a: aPost, b: cLast.y - aPost * cLast.x)
    }

    override func evaluate(at x: Double, epsilon: Double) -> Double {
        if xValueRange.contains(x) {
            return super.evaluate(at: x, epsilon: epsilon)
        } else if x < xValueRange.lower {
            return preLine.evaluate(at: x)
        } else {
            return postLine.evaluate(at: x)
        }
    }
}
