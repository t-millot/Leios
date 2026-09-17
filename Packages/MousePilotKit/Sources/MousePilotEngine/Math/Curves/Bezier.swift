// Bezier.swift
// MousePilot Engine — n-th order Bezier curve in polynomial form with a Newton/bisection x→t solver.
// Ports Shared/Math/Curves/Bezier.swift. Derived from Mac Mouse Fix, MMF License.

import Foundation

class Bezier: Curve {

    static let defaultDefaultEpsilon = 0.08

    let controlPoints: [Vector]
    let controlPointsX: [Double]
    let controlPointsY: [Double]

    private(set) var polynomialCoefficientsX: [Double] = []
    private(set) var polynomialCoefficientsY: [Double] = []

    /// When the Bezier is really just a line we can do some optimizations.
    let isLine: Bool
    let lineRepresentation: Line?

    private let maxDegreeForPolynomialApproach = 20
    let defaultEpsilon: Double

    var degree: Int { controlPoints.count - 1 }
    var n: Int { degree }
    var startPoint: Vector { controlPoints.first! }
    var endPoint: Vector { controlPoints.last! }
    let xValueRange: Interval

    // MARK: Init

    convenience init(points: [(Double, Double)], defaultEpsilon: Double = Bezier.defaultDefaultEpsilon) {
        self.init(controlPoints: points.map { Vector(x: $0.0, y: $0.1) }, defaultEpsilon: defaultEpsilon)
    }

    /// Scales control points from the interval spanned by the first/last points to `xInterval`/`yInterval`.
    convenience init(controlPoints: [Vector], defaultEpsilon: Double = Bezier.defaultDefaultEpsilon, xInterval: Interval, yInterval: Interval) {
        assert(controlPoints.count >= 2)
        let pFirst = controlPoints.first!
        let pLast = controlPoints.last!
        let xOrigin = Interval(start: pFirst.x, end: pLast.x)
        let yOrigin = Interval(start: pFirst.y, end: pLast.y)
        let scaledPoints = controlPoints.map { p in
            Vector(x: Math.scale(value: p.x, from: xOrigin, to: xInterval),
                   y: Math.scale(value: p.y, from: yOrigin, to: yInterval))
        }
        self.init(controlPoints: scaledPoints, defaultEpsilon: defaultEpsilon)
    }

    /// Core init. Control points must describe a curve whose x values are monotonic in t and whose first/last points have the extreme x values.
    init(controlPoints controlPointsArg: [Vector], defaultEpsilon: Double = Bezier.defaultDefaultEpsilon) {
        self.defaultEpsilon = defaultEpsilon

        // Remove consecutive duplicate points.
        var points: [Vector] = []
        var lastPoint: Vector?
        for p in controlPointsArg {
            if let lp = lastPoint, lp.x == p.x, lp.y == p.y { continue }
            points.append(p)
            lastPoint = p
        }
        assert(points.count >= 2, "There need to be at least 2 controlPoints")

        isLine = points.count == 2
        lineRepresentation = isLine ? Line(connecting: points[0], points[1]) : nil

        controlPoints = points
        controlPointsX = points.map { $0.x }
        controlPointsY = points.map { $0.y }
        xValueRange = Interval(lower: controlPointsX.first!, upper: controlPointsX.last!)

        super.init()

        // Precalculate coefficients of the polynomial form (Wikipedia formula).
        let n = self.n
        var cx = [Double](repeating: 0, count: n + 1)
        var cy = [Double](repeating: 0, count: n + 1)
        for j in 0...n {
            var product = 1
            if j >= 1 {
                for m in 0...(j - 1) { product *= n - m }
            }
            var sumX = 0.0
            var sumY = 0.0
            for i in 0...j {
                let a = pow(-1, Double(i + j)) / Double(fac(i) * fac(j - i))
                sumX += a * points[i].x
                sumY += a * points[i].y
            }
            cx[j] = Double(product) * sumX
            cy[j] = Double(product) * sumY
        }
        polynomialCoefficientsX = cx
        polynomialCoefficientsY = cy
    }

    // MARK: Sampling

    private func coefficients(_ axis: MFAxis) -> [Double] {
        axis == .horizontal ? polynomialCoefficientsX : polynomialCoefficientsY
    }

    private func points1D(_ axis: MFAxis) -> [Double] {
        axis == .horizontal ? controlPointsX : controlPointsY
    }

    /// The x or y value of the curve at parameter t ∈ [0, 1].
    func sampleCurve(onAxis axis: MFAxis, atT t: Double) -> Double {
        if degree <= maxDegreeForPolynomialApproach {
            return sampleCurvePolynomial(axis, t)
        } else {
            return sampleCurveCasteljau(axis, t)
        }
    }

    private func sampleCurvePolynomial(_ axis: MFAxis, _ t: Double) -> Double {
        let c = coefficients(axis)
        var sum = 0.0
        for j in stride(from: n, through: 1, by: -1) {
            sum += c[j]
            sum *= t
        }
        sum += c[0]
        return sum
    }

    private func sampleCurveCasteljau(_ axis: MFAxis, _ t: Double) -> Double {
        var pts = points1D(axis)
        var count = pts.count
        while true {
            count -= 1
            for i in 0..<count {
                pts[i] = pts[i] + (pts[i + 1] - pts[i]) * t
            }
            if count == 1 { break }
        }
        return pts[0]
    }

    // MARK: Derivative

    private func sampleDerivative(on axis: MFAxis, at t: Double) -> Double {
        if degree <= maxDegreeForPolynomialApproach {
            return sampleDerivativePolynomial(axis, t)
        } else {
            return sampleDerivativeExplicit(axis, t)
        }
    }

    private func sampleDerivativePolynomial(_ axis: MFAxis, _ t: Double) -> Double {
        let c = coefficients(axis)
        var sum = 0.0
        if n >= 2 {
            for j in stride(from: n, through: 2, by: -1) {
                sum += c[j] * Double(j)
                sum *= t
            }
        }
        sum += c[1]
        return sum
    }

    private func sampleDerivativeExplicit(_ axis: MFAxis, _ t: Double) -> Double {
        let pts = points1D(axis)
        var sum = 0.0
        for i in 0...(n - 1) {
            sum += bernsteinBasisPolynomial(i, n - 1, t) * (pts[i + 1] - pts[i])
        }
        return Double(n) * sum
    }

    private func bernsteinBasisPolynomial(_ i: Int, _ n: Int, _ t: Double) -> Double {
        Double(Math.choose(n, i)) * pow(t, Double(i)) * pow(1 - t, Double(n - i))
    }

    // MARK: t(x)

    private func solveForT(x: Double, epsilon: Double) -> Double {
        let initialGuess = Math.scale(value: x, from: xValueRange, to: .unitInterval, allowOutOfBounds: true)
        let maxNewtonIterations = 8
        var t = initialGuess

        for _ in 1...maxNewtonIterations {
            let sampledXShifted = sampleCurve(onAxis: .horizontal, atT: t) - x
            if abs(sampledXShifted) < epsilon { return t }
            let sampledDerivative = sampleDerivative(on: .horizontal, at: t)
            if abs(sampledDerivative) < 1e-6 { break }
            t = t - sampledXShifted / sampledDerivative
            if t > 1 { t = 1 } else if t < 0 { t = 0 }
        }

        if let tBisect = Math.bisect(searchRange: .unitInterval, targetOutput: x, epsilon: epsilon, function: { self.sampleCurve(onAxis: .horizontal, atT: $0) }) {
            return tBisect
        }
        Log.engine.debug("Bezier: failed to solve for x = \(x); using t = \(t)")
        return t
    }

    // MARK: Evaluate

    override func evaluate(at x: Double) -> Double {
        evaluate(at: x, epsilon: defaultEpsilon)
    }

    func evaluate(at x: Double, epsilon: Double) -> Double {
        if isLine {
            return lineRepresentation!.evaluate(at: x)
        }
        let t = solveForT(x: x, epsilon: epsilon)
        return sampleCurve(onAxis: .vertical, atT: t)
    }

    func derivativeDyOverDx(atT t: Double) -> Double {
        if isLine { return lineRepresentation!.slope }
        if t == 0 { return entrySlope }
        if t == 1 { return exitSlope }
        let dyDt = sampleDerivative(on: .vertical, at: t)
        let dxDt = sampleDerivative(on: .horizontal, at: t)
        return dyDt / dxDt
    }

    var exitSlope: Double {
        if isLine { return lineRepresentation!.slope }
        let cLast = controlPoints[n]
        var idx = n - 1
        var cPrev = controlPoints[idx]
        while cPrev.x == cLast.x && cPrev.y == cLast.y {
            idx -= 1
            cPrev = controlPoints[idx]
        }
        return (cLast.y - cPrev.y) / (cLast.x - cPrev.x)
    }

    var entrySlope: Double {
        if isLine { return lineRepresentation!.slope }
        let cFirst = controlPoints[0]
        var idx = 1
        var cNext = controlPoints[idx]
        while cFirst.x == cNext.x && cFirst.y == cNext.y {
            idx += 1
            cNext = controlPoints[idx]
        }
        return (cNext.y - cFirst.y) / (cNext.x - cFirst.x)
    }
}
