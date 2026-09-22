// TouchAnimator.swift
// Leios Engine — frame-driven animator producing integer deltas with gesture phases and momentum hints.
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
    /// The clock the *running* animation is subscribed to. Deliberately not reused across cold
    /// starts: the pool replaces its clocks on every screen-parameter change, so a clock cached here
    /// can already be dead by the next animation.
    private(set) var clock: FrameClock?
    /// The clock a running animation is moving to, subscribed next to `clock` until it delivers its
    /// first frame. A paused display link takes one to three frames to start, and dropping the old
    /// clock straight away stood the glide still for that long.
    private var incomingClock: FrameClock?
    /// Display whose clock the next cold start should use.
    private var linkedDisplay: CGDirectDisplayID?
    private var clientCallback: Callback?
    private(set) var animationCurve: Curve?
    /// Cached instead of casting `animationCurve` on every frame.
    private var hybridCurve: HybridCurve?

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
    /// `CACurrentMediaTime()` of the last sign of life from the clock: the cold start, then every
    /// frame. Distinct from `lastFrameTime`, which is the *target* time of the frame being drawn
    /// and is left behind by the previous animation until the first frame of the next one.
    private var lastClockActivity: CFTimeInterval = 0
    /// Longer than any frame period a display link delivers while it runs, including a 24 Hz
    /// display and a run loop that was briefly busy.
    private static let clockStallTimeout: CFTimeInterval = 0.25

    private let subPixelator = VectorSubPixelator.biased()

    init(clockPool: FrameClockPool) {
        self.clockPool = clockPool
    }

    // MARK: Interface

    var animationValueLeft: Vector { subtracted(animationValueTotal, lastAnimationValue) }

    func resetSubPixelator() {
        subPixelator.reset()
    }

    /// Picks the frame clock of `display`, and moves a running animation onto it.
    ///
    /// Mac Mouse Fix only relinks between animations. That leaves a scroll which begins on another
    /// display while the last one is still gliding — and every running start after it, which is
    /// all of them while the wheel keeps turning — at the old display's refresh rate: 60 fps on a
    /// 120 Hz screen for as long as the scrolling continues. The animation is timed by the frames'
    /// target timestamps, which share one time base across displays, so it can change clocks
    /// between two frames without changing its course.
    func link(to display: CGDirectDisplayID) {
        linkedDisplay = display
        guard isRunning, let current = clock, let next = clockPool.clock(for: display), next !== incomingClock else { return }
        dropIncomingClock()
        // Back on the display it was leaving, before the move completed.
        guard next !== current else { return }
        // A clock torn down in the meantime refuses the subscription and leaves the animation where it was.
        if subscribe(to: next) { incomingClock = next }
    }

    private func dropIncomingClock() {
        incomingClock?.unsubscribe(ObjectIdentifier(self))
        incomingClock = nil
    }

    // MARK: Start

    func start(params: StartParamsCalculation, callback: @escaping Callback) {
        // A running animation whose clock stopped ticking — its display was unplugged, or the pool
        // tore the clock down under it after a screen-parameter change — would otherwise stay
        // "running" for good: every later start takes the running path, which never subscribes to
        // a clock, and smooth scrolling is dead until something happens to reset it. End it the
        // way a reset would, so the client closes its gesture, and let this start be a cold one.
        if isRunning, CACurrentMediaTime() - lastClockActivity > Self.clockStallTimeout {
            Log.engine.warning("TouchAnimator: frame clock stalled mid-animation; restarting on a live one")
            cancel()
        }
        let p = params(animationValueLeft, isRunning, animationCurve, lastAnimationSpeed)
        // Reset only once the params actually asked for a start. Mac Mouse Fix zeroes this first, so a
        // declined start on a running animation makes the *next* frame re-emit everything the animation
        // has already delivered as one jump.
        guard p.doStart, let curve = p.curve else { return }
        lastAnimationValue = .zero
        startUnsafe(durationRaw: p.duration, durationRawInFrames: p.durationInFrames, value: p.vector, animationCurve: curve, callback: callback)
    }

    private func startUnsafe(durationRaw: CFTimeInterval?, durationRawInFrames: Int?, value: Vector, animationCurve: Curve, callback: @escaping Callback) {
        assert((durationRaw == nil) != (durationRawInFrames == nil))
        if let d = durationRaw { assert(!d.isNaN && d.isFinite && d > 0) }
        if let f = durationRawInFrames { assert(f > 0) }

        clientCallback = callback
        self.animationCurve = animationCurve
        hybridCurve = animationCurve as? HybridCurve

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

    /// Resolves a clock from the pool on every cold start. Caching one across animations used to
    /// leave the animator subscribed to a clock the pool had already torn down after a screen-parameter
    /// change, which marks the animator running while no frame can ever arrive — smooth scrolling
    /// then stops until something resets it.
    private func startClock() {
        guard let clock = clockPool.clock(for: linkedDisplay ?? CGMainDisplayID()) else {
            Log.engine.error("TouchAnimator: no frame clock available; cannot animate")
            return
        }
        guard subscribe(to: clock) else {
            Log.engine.error("TouchAnimator: frame clock was already torn down; cannot animate")
            return
        }
        self.clock = clock
        lastClockActivity = CACurrentMediaTime()
        isRunning = true
    }

    private func subscribe(to clock: FrameClock) -> Bool {
        let source = ObjectIdentifier(clock)
        return clock.subscribe(ObjectIdentifier(self)) { [weak self] timing in
            self?.frameCallback(timing, from: source)
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
        dropIncomingClock()
        isRunning = false
        isFirstCallbackAfterColdStart = false
        isFirstCallbackAfterRunningStart = false
        isLastCallback = false
    }

    // MARK: Frame callback

    private func frameCallback(_ timing: FrameTiming, from source: ObjectIdentifier) {
        guard isRunning else { return }
        if let incoming = incomingClock, ObjectIdentifier(incoming) == source {
            // The new display's clock is ticking, so the old one can let go.
            clock?.unsubscribe(ObjectIdentifier(self))
            clock = incoming
            incomingClock = nil
        }
        lastClockActivity = timing.now
        guard let callback = clientCallback, let animationCurve else {
            assertionFailure("Invalid state - callback/curve can't be nil during running animation")
            return
        }

        var frameTime = timing.outFrame

        // After `link(to:)` moved the animation to another display, the new clock's next frame can
        // be due before the last one the old clock produced — a 120 Hz frame lands inside a 60 Hz
        // one. Animating to it would run the curve backwards and scroll the wrong way by a pixel.
        if !isFirstCallbackAfterColdStart, frameTime <= lastFrameTime { return }

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
        if let hybridCurve {
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
