// DragCurve.swift
// MousePilot Engine — analytically solved drag deceleration `v'(t) = -a·v(t)^b`.
// Ports Shared/Math/Curves/DragCurve.swift (see that file for the derivations). Derived from Mac Mouse Fix, MMF License.

import Foundation

final class DragCurve: Curve {

    private var a: Double = 0
    private var b: Double = 0
    private var c: Double = 0
    private var k: Double = 0
    private var isNegative = false

    // Terms of the solved equations that depend only on `a` and `b`. `evaluate` runs once per frame
    // for the whole length of a momentum scroll, and every one of these was being recomputed there.
    private var oneMinusB: Double = 0
    private var aTimesBMinusOne: Double = 0
    private var aTimesBMinusTwo: Double = 0
    private var distanceExponent: Double = 0

    /// Must run after `a` and `b` are set and before any of the solvers are called.
    private func cacheCoefficients() {
        oneMinusB = 1 - b
        aTimesBMinusOne = a * (b - 1)
        aTimesBMinusTwo = a * (b - 2)
        distanceExponent = 1 / oneMinusB + 1
    }

    private(set) var timeInterval: Interval = .unitInterval
    private var _distanceInterval: Interval = .unitInterval
    var distanceInterval: Interval {
        if isNegative { return Interval(start: -_distanceInterval.start, end: -_distanceInterval.end) }
        return _distanceInterval
    }

    /// Distance-based init: the curve covers exactly `d` before slowing to `stopSpeed`.
    init(coefficient: Double, exponent: Double, distance d: Double, stopSpeed vs: Double) {
        super.init()
        assert(exponent >= 0)
        assert(coefficient > 0)
        assert(mfsign(d) == mfsign(vs))
        assert(vs > 0)

        a = coefficient
        b = exponent
        cacheCoefficients()

        let t_s0 = solveT(v: vs, c: 0)
        k = solveK(d: d, t: t_s0, c: 0)
        c = solveC(d: 0, t: 0, k: k)

        let timeToStop = t_s0 + c
        timeInterval = Interval(0, timeToStop)
        let distanceToStop = solveD(t: timeToStop, c: c, k: k)
        _distanceInterval = Interval(0, distanceToStop)

        assert(abs(timeInterval.length) != .infinity)
    }

    /// Initial-speed-based init: starts at `initialSpeed` and runs until the speed drops to `stopSpeed`.
    init(coefficient: Double, exponent: Double, initialSpeed v0Arg: Double, stopSpeed vsArg: Double) {
        super.init()
        var v0 = v0Arg
        var vs = vsArg

        assert(exponent >= 0)
        assert(coefficient > 0)
        assert(mfsign(v0) == mfsign(vs))
        assert(vs != 0)
        assert(abs(v0) > abs(vs))
        assert(v0 > 0)

        isNegative = mfsign(v0) == -1
        if isNegative {
            v0 *= -1
            vs *= -1
        }

        a = coefficient
        b = exponent
        cacheCoefficients()

        c = solveC(v: v0, t: 0)
        k = solveK(d: 0, t: 0, c: c)

        let timeToStop = solveT(v: vs, c: c)
        let distanceToStop = solveD(t: timeToStop, c: c, k: k)
        timeInterval = Interval(location: 0, length: timeToStop)
        _distanceInterval = Interval(location: 0, length: distanceToStop)

        assert(abs(timeInterval.length) != .infinity)
    }

    // MARK: v(t)

    private func solveV(t: Double, c: Double) -> Double {
        if b == 1 { return exp(-a * (t - c)) }
        return pow(aTimesBMinusOne * (t - c), 1 / oneMinusB)
    }

    private func solveT(v: Double, c: Double) -> Double {
        if b == 1 { return (a * c - log(v)) / a }
        return pow(v, oneMinusB) / aTimesBMinusOne + c
    }

    private func solveC(v: Double, t: Double) -> Double {
        if b == 1 { return (a * t + log(v)) / a }
        return t - (pow(v, oneMinusB) / aTimesBMinusOne)
    }

    // MARK: d(t)

    private func solveD(t: Double, c: Double, k: Double) -> Double {
        if b == 1 { return -exp(a * (c - t)) / a + k }
        if b == 2 { return log(t - c) / a + k }
        return pow(aTimesBMinusOne * (t - c), distanceExponent) / aTimesBMinusTwo + k
    }

    private func solveT(d: Double, c: Double, k: Double) -> Double {
        if b == 1 { return c - log(a * k) / a }
        if b == 2 { return exp(-a * k) + c }
        // One `pow` base, three exponents: the original spelled the same base out four times.
        let base = a * (2 - b) * k
        let inner = pow(base, 1 / (b - 2))
        return (pow(base, -1 / (b - 2)) * (-a * c * inner + a * b * c * inner + pow(base, b / (b - 2))))
            / aTimesBMinusOne
    }

    private func solveC(d: Double, t: Double, k: Double) -> Double {
        let T = solveT(d: d, c: 0, k: k)
        return -(T - t)
    }

    private func solveK(d: Double, t: Double, c: Double) -> Double {
        let D = solveD(t: t, c: c, k: 0)
        return -(D - d)
    }

    // MARK: Interface

    /// Unit time → unit distance, so the curve plugs into TouchAnimator.
    override func evaluate(at tUnit: Double) -> Double {
        let t = Math.scale(value: tUnit, from: .unitInterval, to: timeInterval, allowOutOfBounds: true)
        let d = solveD(t: t, c: c, k: k)
        var dUnit = Math.scale(value: d, from: distanceInterval, to: .unitInterval, allowOutOfBounds: true)
        if isNegative { dUnit *= -1 }
        return dUnit
    }
}
