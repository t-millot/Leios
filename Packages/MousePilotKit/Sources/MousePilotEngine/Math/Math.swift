// Math.swift
// MousePilot Engine — scaling, bisection, interval type (ports Shared/Math/Math.swift).
// Derived from Mac Mouse Fix, MMF License.

import Foundation

enum IntervalDirection {
    case ascending, descending, none
}

/// A closed interval of real numbers that also remembers a direction (start → end).
struct Interval: Equatable, CustomStringConvertible {
    let start: Double
    let end: Double

    static let unitInterval = Interval(start: 0, end: 1)
    static let reversedUnitInterval = Interval(start: 1, end: 0)

    init(start: Double, end: Double) {
        assert(!start.isNaN && !end.isNaN && start.isFinite && end.isFinite)
        self.start = start
        self.end = end
    }

    init(_ a: Double, _ b: Double) { self.init(start: a, end: b) }

    init(lower: Double, upper: Double) {
        assert(lower < upper)
        self.init(start: lower, end: upper)
    }

    init(location: Double, length: Double) {
        self.init(lower: location, upper: location + length)
    }

    var direction: IntervalDirection {
        if start == end { return .none }
        return start < end ? .ascending : .descending
    }
    var lower: Double { min(start, end) }
    var upper: Double { max(start, end) }
    var location: Double { lower }
    var length: Double { upper - lower }
    var directedLength: Double { end - start }

    func contains(_ value: Double) -> Bool { lower <= value && value <= upper }

    var description: String { "(\(start), \(end))" }
}

func directionsAreOpposite(_ a: IntervalDirection, _ b: IntervalDirection) -> Bool {
    if a == .none || b == .none { return false }
    return a != b
}

enum Math {

    static func clamp(_ x: Double, _ range: (Double, Double)) -> Double {
        min(max(x, range.0), range.1)
    }

    /// Generalization of modulo. NOTE: Deliberately keeps Mac Mouse Fix's inclusive-bound quirk (ClickCycle relies on it).
    static func intCycle(x: Int, lower: Int, upper: Int) -> Int {
        Int(cycle(x: Double(x), lower: Double(lower), upper: Double(upper)))
    }

    static func cycle(x: Double, lower: Double, upper: Double) -> Double {
        assert(lower <= upper)
        if lower == upper { return lower }
        var x = x
        let stride = upper - lower
        while upper < x { x -= stride }
        while x < lower { x += stride }
        return x
    }

    /// Bisection search for the input of a monotonically increasing function that yields `targetOutput`.
    static func bisect(searchRange: Interval, targetOutput: Double, epsilon: Double, function: (Double) -> Double) -> Double? {
        assert(searchRange.upper - searchRange.lower > 0)
        assert(epsilon > 0)

        let validationFrequency = 10
        var iterationCounter = 0
        var range = searchRange
        var t = Math.scale(value: 0.5, from: .unitInterval, to: range)

        while range.lower != range.upper {
            let sampledOutput = function(t)
            if abs(targetOutput - sampledOutput) < epsilon { return t }
            if sampledOutput < targetOutput {
                range = Interval(t, range.upper)
            } else {
                range = Interval(range.lower, t)
            }
            iterationCounter += 1
            if iterationCounter % validationFrequency == 0 {
                let lowerOutput: Double
                let upperOutput: Double
                if sampledOutput < targetOutput {
                    lowerOutput = sampledOutput
                    upperOutput = function(range.upper)
                } else {
                    lowerOutput = function(range.lower)
                    upperOutput = sampledOutput
                }
                let targetTooSmall = targetOutput < lowerOutput
                let targetTooLarge = upperOutput < targetOutput
                if targetTooSmall || targetTooLarge {
                    Log.engine.error("Bisection failed; function is probably not monotonically increasing. target: \(targetOutput)")
                    return targetTooSmall ? range.lower : range.upper
                }
            }
            if range.length == 0 { break }
            t = Math.scale(value: 0.5, from: .unitInterval, to: range)
        }
        return nil
    }

    static func choose(_ nArg: Int, _ k: Int) -> Int {
        var n = nArg
        var r = 1
        assert(n >= 0 && k >= 0)
        if k < 0 || n < k { return 0 }
        if k == 0 || k == n { return 1 }
        for d in 1...k {
            r *= n
            r /= d
            n -= 1
        }
        return r
    }

    static func factorial(_ n: Int) -> Int {
        assert(n >= 0)
        return n == 0 ? 1 : n * factorial(n - 1)
    }

    static func scale(_ value: Double, _ from: (Double, Double), _ to: (Double, Double), checkBounds: Bool = true) -> Double {
        Math.scale(value: value, from: Interval(from.0, from.1), to: Interval(to.0, to.1), allowOutOfBounds: !checkBounds)
    }

    static func scale(value: Double, from originInterval: Interval, to targetInterval: Interval, allowOutOfBounds: Bool = false) -> Double {
        if !allowOutOfBounds {
            assert(originInterval.contains(value), "value \(value) not in \(originInterval)")
        }
        assert(!value.isNaN && !value.isInfinite && value.magnitude != .greatestFiniteMagnitude)
        assert(originInterval.length > 0)

        var unitValue = (value - originInterval.lower) / originInterval.length
        if directionsAreOpposite(originInterval.direction, targetInterval.direction) {
            unitValue = unitValue - 2 * (unitValue - 0.5)
        }
        let result = targetInterval.lower + (unitValue * targetInterval.length)
        assert(!result.isNaN)
        return result
    }

    static func nthroot(value: Double, _ n: Double) -> Double {
        if value < 0 && abs(n.truncatingRemainder(dividingBy: 2)) == 1 {
            return -pow(-value, 1 / n)
        }
        return pow(value, 1 / n)
    }

    /// Rounds `value` up to the next multiple of `multiple` (ports ModificationUtility.roundUp:toMultiple:).
    static func roundUp(_ value: Double, toMultiple multiple: Double) -> Double {
        if multiple <= 0 { return value }
        let remainder = value.truncatingRemainder(dividingBy: multiple)
        if remainder == 0 { return value }
        return value + multiple - remainder
    }
}

func fac(_ n: Int) -> Int { Math.factorial(n) }
