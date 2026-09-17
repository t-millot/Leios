// Curve.swift
// MousePilot Engine — base class for animation and acceleration curves (ports Shared/Math/Curves/Curve.swift).
// Derived from Mac Mouse Fix, MMF License.

import Foundation

typealias RawCurve = (Double) -> Double

enum CurveTools {
    /// Returns a new curve which applies `transform` to the output of `curve`.
    static func transformCurve(_ curve: @escaping RawCurve, _ transform: @escaping (Double) -> Double) -> RawCurve {
        { x in transform(curve(x)) }
    }
}

class Curve {

    private let rawCurve: RawCurve?

    init() { rawCurve = nil }

    init(rawCurve: @escaping RawCurve) {
        self.rawCurve = rawCurve
    }

    /// TouchAnimator expects animation curves to pass through (0,0) and (1,1).
    func evaluate(at x: Double) -> Double {
        if let rawCurve { return rawCurve(x) }
        fatalError("Curve subclass must override evaluate(at:)")
    }
}
