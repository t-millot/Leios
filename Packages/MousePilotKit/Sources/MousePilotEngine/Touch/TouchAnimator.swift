// TouchAnimator.swift
// MousePilot Engine — frame-driven animator producing integer deltas with gesture phases and momentum hints.
// Merged port of Helper/Core/Touch/TouchAnimatorBase.swift + TouchAnimator.swift. Runs entirely on the engine thread,
// so none of the original queue/lock plumbing is needed. Derived from Mac Mouse Fix, MMF License.

import Foundation
import QuartzCore

struct AnimatorStartParams {
    var doStart = true
    var duration: CFTimeInterval?
    var durationInFrames: Int?
    var vector: Vector = .zero
    var curve: Curve?

    static let skip = AnimatorStartParams(doStart: false)
}

final class TouchAnimator {

    typealias Callback = (_ integerDelta: Vector, _ phase: AnimationCallbackPhase, _ momentumHint: MomentumHint) -> Void
    typealias StartParamsCalculation = (_ valueLeft: Vector, _ isRunning: Bool, _ curve: Curve?, _ currentSpeed: Vector) -> AnimatorStartParams

    static func callbackPhase(hasProducedDeltas: Bool, isLastCallback: Bool) -> AnimationCallbackPhase {
        assert(!(!hasProducedDeltas && isLastCallback))
        if isLastCallback { return .end }
        if !hasProducedDeltas { return .start }
        return .continue
    }

    /// With fast scroll the duration can become absurdly large, so it is capped.
    let maxAnimationDuration: CFTimeInterval = 1.5
    /// The first `minBaseCurveTime` seconds of a hybrid animation always hint `gesture` (Xcode ignores momentum deltas).
    var minBaseCurveTime: CFTimeInterval = 0.160

    private let clockPool: FrameClockPool
    private var clock: FrameClock?
    private var clientCallback: Callback?
    private(set) var animationCurve: Curve?

    private var animationDurationRaw: CFTimeInterval?
    private var animationDurationRawInFrames: Int?
    private var animationDuration: CFTimeInterval = 0
    private var animationStartTime: CFTimeInterval = 0
    private var animationEndTime: CFTimeInterval { animationStartTime + animationDuration }
    private var animationValueTotal: Vector = .zero

    private(set) var isRunning = false

    private var isFirstCallbackAfterColdStart = false
    private var isFirstCallbackAfterRunningStart = false
    private var isLastCallback = false
    private var thisAnimationHasProducedDeltas = false

    private var lastAnimationValue: Vector = .zero
    private var lastAnimationTimeUnit: Double = 0
    private var lastMomentumHint: MomentumHint = .none
    private(set) var lastAnimationSpeed: Vector = .zero
    private var lastFrameTime: CFTimeInterval = -1

    private let subPixelator = VectorSubPixelator.biased()

    init(clockPool: FrameClockPool) {
        self.clockPool = clockPool
    }

    // MARK: Interface

    var animationValueLeft: Vector { subtracted(animationValueTotal, lastAnimationValue) }
    var animationTimeLeft: Double { animationEndTime - lastFrameTime }

    func resetSubPixelator() {
        subPixelator.reset()
    }

    /// Picks the frame clock of `display`. Only takes effect for the next cold start.
    func link(to display: CGDirectDisplayID) {
        if isRunning { return }
        clock = clockPool.clock(for: display)
    }

    func linkToMainScreen() {
        link(to: CGMainDisplayID())
    }

    // MARK: Start

    func start(params: StartParamsCalculation, callback: @escaping Callback) {
        let p = params(animationValueLeft, isRunning, animationCurve, lastAnimationSpeed)
        lastAnimationValue = .zero
        guard p.doStart, let curve = p.curve else { return }
        startUnsafe(durationRaw: p.duration, durationRawInFrames: p.durationInFrames, value: p.vector, animationCurve: curve, callback: callback)
    }

    private func startUnsafe(durationRaw: CFTimeInterval?, durationRawInFrames: Int?, value: Vector, animationCurve: Curve, callback: @escaping Callback) {
        assert((durationRaw == nil) != (durationRawInFrames == nil))
        if let d = durationRaw { assert(!d.isNaN && d.isFinite && d > 0) }
        if let f = durationRawInFrames { assert(f > 0) }

        clientCallback = callback
        self.animationCurve = animationCurve

        let wasRunning = isRunning

        if !wasRunning || isFirstCallbackAfterColdStart {
            isFirstCallbackAfterColdStart = true
            isFirstCallbackAfterRunningStart = false
            isLastCallback = false
            thisAnimationHasProducedDeltas = false
            lastMomentumHint = .none
            lastAnimationSpeed = .zero
        } else {
            isFirstCallbackAfterRunningStart = true
        }

        if wasRunning {
            animationStartTime = lastFrameTime
            animationDuration = -1
            animationDurationRaw = durationRaw
            animationDurationRawInFrames = durationRawInFrames
            animationValueTotal = value
        } else {
            animationStartTime = -1
            animationDuration = -1
            animationDurationRaw = durationRaw
            animationDurationRawInFrames = durationRawInFrames
            animationValueTotal = value
            startClock()
        }
    }

    private func startClock() {
        if clock == nil { clock = clockPool.clock(for: CGMainDisplayID()) }
        guard let clock else {
            Log.engine.error("TouchAnimator: no frame clock available; cannot animate")
            return
        }
        isRunning = true
        clock.subscribe(ObjectIdentifier(self)) { [weak self] timing in
            self?.frameCallback(timing)
        }
    }

    // MARK: Cancel / stop

    func cancel() {
        let wasRunning = isRunning
        let hadProducedDeltas = thisAnimationHasProducedDeltas
        stop()
        if wasRunning, hadProducedDeltas, let callback = clientCallback {
            callback(.zero, .canceled, lastMomentumHint)
        }
    }

    private func stop() {
        lastAnimationSpeed = .zero
        if isRunning {
            clock?.unsubscribe(ObjectIdentifier(self))
        }
        isRunning = false
        isFirstCallbackAfterColdStart = false
        isFirstCallbackAfterRunningStart = false
        isLastCallback = false
    }

    // MARK: Frame callback

    private func frameCallback(_ timing: FrameTiming) {
        guard isRunning else { return }
        guard let callback = clientCallback, let animationCurve else {
            assertionFailure("Invalid state - callback/curve can't be nil during running animation")
            return
        }

        var frameTime = timing.outFrame

        if isFirstCallbackAfterColdStart {
            // Hypothetical last frame, so the first time delta is the same size as all the others.
            lastFrameTime = frameTime - timing.nominalTimeBetweenFrames
            animationStartTime = lastFrameTime
            lastAnimationTimeUnit = -1
        }

        if isFirstCallbackAfterColdStart || isFirstCallbackAfterRunningStart {
            // Round the duration to a multiple of the frame time so the last delta is the same size as the others.
            if let raw = animationDurationRaw {
                animationDuration = Math.roundUp(raw, toMultiple: timing.nominalTimeBetweenFrames)
            } else if let frames = animationDurationRawInFrames {
                animationDuration = Double(frames) * timing.nominalTimeBetweenFrames
            } else {
                assertionFailure()
            }
            assert(animationDuration >= 0)
            if animationDuration > maxAnimationDuration { animationDuration = maxAnimationDuration }
        }

        if lastFrameTime >= animationEndTime {
            isLastCallback = true
        }

        let closerToEndTimeThanNextFrame = abs(frameTime - animationEndTime) < abs(frameTime + timing.timeBetweenFrames - animationEndTime)
        let pastEndTime = animationEndTime <= frameTime
        if closerToEndTimeThanNextFrame || pastEndTime {
            frameTime = animationEndTime
        }

        let animationTimeInterval = Interval(location: animationStartTime, length: animationDuration)
        let animationTimeUnit = Math.scale(value: frameTime, from: animationTimeInterval, to: .unitInterval, allowOutOfBounds: true)
        let animationValueUnit = animationCurve.evaluate(at: animationTimeUnit)

        // Momentum hint
        var momentumHint: MomentumHint = .none
        if let hybridCurve = animationCurve as? HybridCurve {
            var subCurve = hybridCurve.subCurve(at: animationTimeUnit)
            if lastAnimationTimeUnit != -1 {
                // Only hint 'drag' when all of this frame's pixels come from the drag curve.
                if hybridCurve.subCurve(at: lastAnimationTimeUnit) == .base {
                    subCurve = .base
                }
            }
            let timeSinceAnimationStart = frameTime - animationStartTime
            if timeSinceAnimationStart < minBaseCurveTime {
                momentumHint = .gesture
            } else {
                momentumHint = subCurve == .base ? .gesture : .momentum
            }
        }

        var animationValue: Vector = .zero
        if animationValueTotal.x != 0 {
            animationValue.x = Math.scale(value: animationValueUnit, from: .unitInterval, to: Interval(start: 0, end: animationValueTotal.x), allowOutOfBounds: true)
        }
        if animationValueTotal.y != 0 {
            animationValue.y = Math.scale(value: animationValueUnit, from: .unitInterval, to: Interval(start: 0, end: animationValueTotal.y), allowOutOfBounds: true)
        }

        let animationTimeDelta = frameTime - lastFrameTime
        let animationValueDelta = subtracted(animationValue, lastAnimationValue)

        // Integer output (TouchAnimator subclass hook in Mac Mouse Fix)
        let intValueLeft = subPixelator.peekIntVector(animationValueLeft)
        if isZeroVector(intValueLeft) {
            isLastCallback = true
        }
        let integerDelta = subPixelator.intVector(animationValueDelta)

        if isZeroVector(integerDelta) && !isLastCallback {
            // Skip this frame's callback and don't advance the phase.
        } else {
            let isEndAndNoPrecedingDeltas = isLastCallback && !thisAnimationHasProducedDeltas
            if !isEndAndNoPrecedingDeltas {
                let phase = TouchAnimator.callbackPhase(hasProducedDeltas: thisAnimationHasProducedDeltas, isLastCallback: isLastCallback)
                callback(integerDelta, phase, momentumHint)
            }
            thisAnimationHasProducedDeltas = true
        }

        lastFrameTime = frameTime
        lastAnimationValue = animationValue
        lastAnimationTimeUnit = animationTimeUnit
        lastMomentumHint = momentumHint
        if !isLastCallback && animationTimeDelta > 0 {
            lastAnimationSpeed = scaled(animationValueDelta, 1.0 / animationTimeDelta)
        }
        assert(!vectorHasNaN(lastAnimationSpeed))

        if isLastCallback {
            stop()
            return
        }

        isFirstCallbackAfterColdStart = false
        isFirstCallbackAfterRunningStart = false
    }
}
