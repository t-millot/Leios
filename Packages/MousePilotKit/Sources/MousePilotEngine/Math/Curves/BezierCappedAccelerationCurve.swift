// BezierCappedAccelerationCurve.swift
// MousePilot Engine — the scroll acceleration curve: `curvature + 1` control points equidistant in x,
// y = yMin for the first and yMax for the rest. Ports Shared/Math/Curves/BezierCappedAccelerationCurve.swift.
// Derived from Mac Mouse Fix, MMF License.

import Foundation

final class BezierCappedAccelerationCurve: AccelerationBezier {

    init(xMin: Double, xMax: Double, yMin: Double, yMax: Double, curvature: Double, reduceToCubic: Bool = false, defaultEpsilon: Double = Bezier.defaultDefaultEpsilon) {
        let degree = curvature + 1
        assert(degree >= 1)

        var points: [Vector] = []
        var i = 0
        while true {
            let isLast = Double(i) >= degree
            if reduceToCubic {
                let isFirstThree = i <= 2
                if !isFirstThree && !isLast {
                    i += 1
                    continue
                }
            }
            var x = Math.scale(Double(i) / degree, (0, 1), (xMin, xMax), checkBounds: false)
            if x > xMax {
                assert(isLast)
                x = xMax
            }
            let y = i == 0 ? yMin : yMax
            points.append(Vector(x: x, y: y))
            if isLast { break }
            i += 1
        }
        super.init(controlPoints: points, defaultEpsilon: defaultEpsilon)
    }
}
