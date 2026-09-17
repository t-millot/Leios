// Line.swift
// MousePilot Engine — y = ax + b (ports Shared/Math/Curves/Line.swift).
// Derived from Mac Mouse Fix, MMF License.

import Foundation

final class Line: Curve {

    let a: Double
    let b: Double

    var slope: Double { a }

    init(a: Double, b: Double) {
        self.a = a
        self.b = b
        super.init()
    }

    convenience init(p: Vector, slope a: Double) {
        self.init(a: a, b: p.y - a * p.x)
    }

    convenience init(connecting p1: Vector, _ p2: Vector) {
        let a = (p2.y - p1.y) / (p2.x - p1.x)
        self.init(a: a, b: p1.y - a * p1.x)
    }

    override func evaluate(at x: Double) -> Double {
        a * x + b
    }

    func evaluate(atY y: Double) -> Double {
        (y - b) / a
    }
}
