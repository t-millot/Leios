// ScrollSpeedupCurve.swift
// Leios Engine — fast-scroll multiplier as a function of consecutive swipes (ports Shared/Math/Curves/ScrollSpeedupCurve.swift).
// See https://www.desmos.com/calculator/cdd0jlgnqt. Derived from Mac Mouse Fix, MMF License.

import Foundation

final class ScrollSpeedupCurve: Curve {

    let a: Double
    let b: Double
    let c: Double
    let t: Double
    let p: Double

    init(swipeThreshold t: Int, initialSpeedup p: Double, exponentialSpeedup c: Double) {
        assert(t > 0 && p >= 1.0)
        self.b = 1.1
        self.a = (p - 1.0) / (pow(b, c) - 1)
        self.c = c
        self.t = Double(t)
        self.p = p
        super.init()
    }

    override func evaluate(at x: Double) -> Double {
        if x < t { return 1.0 }
        return a * pow(b, (x - t) * c) + 1 - a
    }
}
