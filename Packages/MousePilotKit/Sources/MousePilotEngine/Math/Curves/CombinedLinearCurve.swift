// CombinedLinearCurve.swift
// MousePilot Engine — piecewise-linear interpolation over equidistant y values (ports Shared/Math/Curves/CombinedLinearCurve.swift).
// Derived from Mac Mouse Fix, MMF License.

import Foundation

struct CombinedLinearCurve {

    let points: [Vector]
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double

    /// x values are equidistant between 0 and 1.
    init(yValues: [Double]) {
        var points: [Vector] = []
        for i in 0..<yValues.count {
            points.append(Vector(x: Double(i) / Double(yValues.count - 1), y: yValues[i]))
        }
        self.init(points: points)
    }

    init(points: [Vector]) {
        assert(points.count >= 2)
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        for p in points {
            assert(p.x > maxX)
            maxX = p.x
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        self.minX = points.first!.x
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.points = points
    }

    func evaluate(atX x: Double) -> Double {
        assert(minX <= x && x <= maxX)
        var p1: Vector?
        var p2: Vector?
        for i in 0..<points.count where x < points[i].x {
            p1 = points[i - 1]
            p2 = points[i]
            break
        }
        if p1 == nil, x == points.last!.x {
            p1 = points[points.count - 2]
            p2 = points[points.count - 1]
        }
        guard let a = p1, let b = p2 else { fatalError("x out of range") }
        let unitX = (x - a.x) / (b.x - a.x)
        return unitX * (b.y - a.y) + a.y
    }
}
