// SubPixelator.swift
// Leios Engine — accumulates rounding error so integer deltas sum to the real ones.
// Ports Shared/Utility/SubPixelator/{SubPixelator,VectorSubPixelator}.m. Derived from Mac Mouse Fix, MMF License.

import Foundation

final class SubPixelator {

    typealias RoundingFunction = (Double) -> Double

    private var accumulatedRoundingError = 0.0
    private var roundingFunction: RoundingFunction?
    private let isBiased: Bool
    /// Only pixelate if `abs(value) < threshold`.
    var threshold: Double

    static func ceil() -> SubPixelator { SubPixelator(roundingFunction: { Foundation.ceil($0) }, threshold: .infinity) }
    static func round() -> SubPixelator { SubPixelator(roundingFunction: { Foundation.round($0) }, threshold: .infinity) }
    static func floor() -> SubPixelator { SubPixelator(roundingFunction: { Foundation.floor($0) }, threshold: .infinity) }
    /// Becomes a ceil or floor pixelator depending on whether its first non-zero input is positive or negative,
    /// so the first input always yields a non-zero output.
    static func biased() -> SubPixelator { SubPixelator(biasedWithThreshold: .infinity) }

    init(roundingFunction: @escaping RoundingFunction, threshold: Double) {
        self.roundingFunction = roundingFunction
        self.isBiased = false
        self.threshold = threshold
    }

    init(biasedWithThreshold threshold: Double) {
        self.roundingFunction = nil
        self.isBiased = true
        self.threshold = threshold
    }

    private static func biasedRoundingFunction(for delta: Double) -> RoundingFunction? {
        switch mfsign(delta) {
        case 1: return { Foundation.ceil($0) }
        case -1: return { Foundation.floor($0) }
        default: return nil
        }
    }

    func intDelta(_ inputDelta: Double) -> Double {
        // NaN has no sign, so the biased pixelator has no rounding function to pick and the unwrap
        // below would trap. The asserts that would catch a NaN upstream are compiled out in Release.
        if inputDelta == 0 || inputDelta.isNaN { return 0 }
        let rf: RoundingFunction
        if isBiased && roundingFunction == nil {
            rf = SubPixelator.biasedRoundingFunction(for: inputDelta)!
            roundingFunction = rf
        } else {
            rf = roundingFunction!
        }
        let preciseDelta = inputDelta + accumulatedRoundingError
        let outputDelta: Double
        if greaterEqual(abs(preciseDelta), threshold, tolerance: 10e-4) {
            outputDelta = preciseDelta
        } else {
            outputDelta = rf(preciseDelta)
        }
        accumulatedRoundingError = preciseDelta - outputDelta
        return outputDelta
    }

    /// The output a certain input would yield, without changing state.
    func peekIntDelta(_ inputDelta: Double) -> Double {
        if inputDelta == 0 || inputDelta.isNaN { return 0 }
        let rf: RoundingFunction
        if let existing = roundingFunction {
            rf = existing
        } else {
            rf = SubPixelator.biasedRoundingFunction(for: inputDelta)!
            assert(accumulatedRoundingError == 0)
        }
        let preciseDelta = inputDelta + accumulatedRoundingError
        if greaterEqual(abs(preciseDelta), threshold, tolerance: 10e-4) {
            return preciseDelta
        }
        return rf(preciseDelta)
    }

    func reset() {
        accumulatedRoundingError = 0
        if isBiased { roundingFunction = nil }
    }
}

final class VectorSubPixelator {

    private let spX: SubPixelator
    private let spY: SubPixelator

    static func ceil() -> VectorSubPixelator { VectorSubPixelator(x: .ceil(), y: .ceil()) }
    static func round() -> VectorSubPixelator { VectorSubPixelator(x: .round(), y: .round()) }
    static func floor() -> VectorSubPixelator { VectorSubPixelator(x: .floor(), y: .floor()) }
    static func biased() -> VectorSubPixelator { VectorSubPixelator(x: .biased(), y: .biased()) }

    private init(x: SubPixelator, y: SubPixelator) {
        spX = x
        spY = y
    }

    var threshold: Double {
        get { spX.threshold }
        set { spX.threshold = newValue; spY.threshold = newValue }
    }

    func intVector(_ v: Vector) -> Vector {
        Vector(x: spX.intDelta(v.x), y: spY.intDelta(v.y))
    }

    func peekIntVector(_ v: Vector) -> Vector {
        Vector(x: spX.peekIntDelta(v.x), y: spY.peekIntDelta(v.y))
    }

    func reset() {
        spX.reset()
        spY.reset()
    }
}
