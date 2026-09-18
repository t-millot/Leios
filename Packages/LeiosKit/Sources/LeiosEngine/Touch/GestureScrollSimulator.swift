// GestureScrollSimulator.swift
// Leios Engine — posts scroll events that look like they come from an Apple trackpad, plus automatic momentum scrolling.
// Ports Helper/Core/Touch/GestureScrollSimulator.m. Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics
import QuartzCore

final class GestureScrollSimulator {

    private let scrollLinePixelator = VectorSubPixelator.biased()
    private let momentumAnimator: TouchAnimator

    private var lastInputTime: CFTimeInterval = 0
    private var lastScrollVec: Vector = .zero

    /// One-shot: called after momentum scrolling has started (first momentum event posted), or immediately when it
    /// was decided not to start. Replaces Mac Mouse Fix's `afterStartingMomentumScroll:` + dispatch-group wait.
    var onMomentumStarted: (() -> Void)?

    /// True from the moment the momentum animator is asked to start until its first callback. A stop in
    /// that window has to resolve `onMomentumStarted` too — otherwise nothing ever reports back and
    /// `TwoFingerSwipeOutput` keeps the pointer frozen until its watchdog fires half a second later.
    /// It is deliberately *not* set while a one-shot merely waits for a momentum scroll that has not
    /// been requested yet, so installing the callback and then posting an `ended` phase cannot fire it early.
    private var momentumStartPending = false

    /// Ports `GeneralConfig.mouseMovingMaxIntervalLarge`.
    static let mouseMovingMaxIntervalLarge: CFTimeInterval = 0.1

    init(clockPool: FrameClockPool) {
        momentumAnimator = TouchAnimator(clockPool: clockPool)
    }

    var isMomentumScrolling: Bool { momentumAnimator.isRunning }

    // MARK: Main interface

    /// Post scroll events that behave as if they are coming from a trackpad. With `autoMomentumScroll`, momentum
    /// scrolling starts automatically after the `ended` phase, based on the last non-zero deltas.
    func postGestureScroll(dx: Int64, dy: Int64, phase: IOHIDPhase, autoMomentumScroll: Bool, invertedFromDevice: Bool) {
        if dx == 0 && dy == 0 && !(phase == .ended || phase == .mayBegin || phase == .cancelled) {
            Log.touch.warning("Ignoring gesture scroll with zero deltas in phase \(phase.rawValue)")
            assertionFailure()
            return
        }

        stopMomentumScroll()

        let now = CACurrentMediaTime()
        let timeSinceLastInput: CFTimeInterval = phase == .began ? .greatestFiniteMagnitude : now - lastInputTime

        if phase == .began {
            scrollLinePixelator.reset()
        }

        switch phase {
        case .began, .changed, .mayBegin, .cancelled:
            let point = Vector(x: Double(dx), y: Double(dy))
            let (line, lineInt, gesture) = deltaVectors(point: point, wantGesture: true)
            lastScrollVec = point
            postGestureScrollEvent(gesture: gesture, line: line, lineInt: lineInt, point: point, phase: phase, momentumPhase: .none, invertedFromDevice: invertedFromDevice)
        case .ended:
            postGestureScrollEvent(gesture: .zero, line: .zero, lineInt: .zero, point: .zero, phase: .ended, momentumPhase: .none, invertedFromDevice: invertedFromDevice)
            if autoMomentumScroll {
                let exitVelocity = Vector(x: lastScrollVec.x / timeSinceLastInput, y: lastScrollVec.y / timeSinceLastInput)
                // Parameters that emulate a real trackpad's momentum scroll.
                startMomentumScroll(timeSinceLastInput: timeSinceLastInput, exitVelocity: exitVelocity, stopSpeed: 1.0, dragCoefficient: 30.0, dragExponent: 0.7, invertedFromDevice: invertedFromDevice)
            }
        case .undefined:
            Log.touch.error("Invalid gesture scroll phase")
            assertionFailure()
        }

        lastInputTime = now
    }

    /// Post a momentum-scroll event directly (used by the scroll wheel trackpad simulation).
    func postMomentumScrollDirectly(dx: Double, dy: Double, momentumPhase: CGMomentumScrollPhase, invertedFromDevice: Bool) {
        if momentumPhase == .begin {
            scrollLinePixelator.reset()
        }
        let point = Vector(x: dx, y: dy)
        let (line, lineInt, _) = deltaVectors(point: point, wantGesture: false)
        postGestureScrollEvent(gesture: .zero, line: line, lineInt: lineInt, point: point, phase: .undefined, momentumPhase: momentumPhase, invertedFromDevice: invertedFromDevice)
    }

    // MARK: Momentum scroll

    func stopMomentumScroll() {
        let wasPending = momentumStartPending
        momentumStartPending = false
        momentumAnimator.cancel()
        // Cancelled before its first frame, so the `.start` callback that normally resolves the
        // one-shot will never run.
        if wasPending { fireMomentumStarted() }
    }

    private func fireMomentumStarted() {
        let cb = onMomentumStarted
        onMomentumStarted = nil
        cb?()
    }

    private func startMomentumScroll(timeSinceLastInput: CFTimeInterval, exitVelocity: Vector, stopSpeed: Double, dragCoefficient: Double, dragExponent: Double, invertedFromDevice: Bool) {
        // Stop immediately if the mouse was stationary before release.
        if GestureScrollSimulator.mouseMovingMaxIntervalLarge < timeSinceLastInput || timeSinceLastInput == .greatestFiniteMagnitude {
            fireMomentumStarted()
            stopMomentumScroll()
            return
        }

        momentumAnimator.resetSubPixelator()
        momentumAnimator.linkToMainScreen()

        momentumStartPending = true
        momentumAnimator.start(params: { [self] _, _, _, _ in
            scrollLinePixelator.reset()
            let initialVelocity = exitVelocity
            let initialSpeed = magnitude(initialVelocity)
            if initialSpeed <= stopSpeed {
                fireMomentumStarted()
                return .skip
            }
            let curve = DragCurve(coefficient: dragCoefficient, exponent: dragExponent, initialSpeed: initialSpeed, stopSpeed: stopSpeed)
            let duration = curve.timeInterval.length
            let distance = curve.distanceInterval.length
            let distanceVec = scaled(unitVector(initialVelocity), distance)
            return AnimatorStartParams(doStart: true, duration: duration, vector: distanceVec, curve: curve)
        }, callback: { [self] deltaVec, animationPhase, _ in
            let (line, lineInt, _) = deltaVectors(point: deltaVec, wantGesture: false)
            let momentumPhase: CGMomentumScrollPhase
            switch animationPhase {
            case .start: momentumPhase = .begin
            case .continue: momentumPhase = .continuous
            case .end, .canceled: momentumPhase = .end
            case .none: momentumPhase = .none
            }
            postGestureScrollEvent(gesture: .zero, line: line, lineInt: lineInt, point: deltaVec, phase: .undefined, momentumPhase: momentumPhase, invertedFromDevice: invertedFromDevice)

            // Simulate a two-finger tap to prevent apps from adding their own momentum.
            if animationPhase == .end || animationPhase == .canceled {
                postGestureScrollEvent(gesture: .zero, line: .zero, lineInt: .zero, point: .zero, phase: .mayBegin, momentumPhase: .none, invertedFromDevice: invertedFromDevice)
                postGestureScrollEvent(gesture: .zero, line: .zero, lineInt: .zero, point: .zero, phase: .cancelled, momentumPhase: .none, invertedFromDevice: invertedFromDevice)
            }
            if animationPhase == .start {
                momentumStartPending = false
                fireMomentumStarted()
            }
        })

        // The params closure ran synchronously. If it declined to start — or the animator could not
        // find a frame clock to run on — no callback is ever coming, so resolve the one-shot now
        // instead of leaving the caller's watchdog to notice.
        if !momentumAnimator.isRunning {
            momentumStartPending = false
            fireMomentumStarted()
        }
    }

    // MARK: Vectors

    /// `point` → (line, lineInt, gesture) as the trackpad driver would produce them.
    private func deltaVectors(point: Vector, wantGesture: Bool) -> (Vector, Vector, Vector) {
        assert(point.x == point.x.rounded() && point.y == point.y.rounded())
        scrollLinePixelator.threshold = .infinity
        var line = scaled(point, 1.0 / 10) // CGEventSource.pixelsPerLine == 10
        line = scrollLinePixelator.intVector(line)
        let lineInt = vectorByApplying(line) { v in abs(v) <= 1.0 ? signedCeil(v) : signedFloor(v) }
        let gesture = wantGesture ? scaled(point, 1.67) : .zero // 1.67 makes Safari page swipes appropriately easy to trigger
        return (line, lineInt, gesture)
    }

    // MARK: CGEvents

    /// Posts a type-22 scroll event and (for gesture phases) a type-29/subtype-6 gesture event.
    func postGestureScrollEvent(gesture: Vector, line: Vector, lineInt: Vector, point: Vector, phase: IOHIDPhase, momentumPhase: CGMomentumScrollPhase, invertedFromDevice: Bool) {
        assert(phase == .undefined || momentumPhase == .none)

        let eventTs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))

        guard let e22 = CGEvent(source: nil) else { return }
        e22.setInt(55, 22)                                  // NSEventTypeScrollWheel
        e22.setInt(88, 1)                                   // kCGScrollWheelEventIsContinuous
        e22.setInt(137, invertedFromDevice ? 1 : 0)         // directionInvertedFromDevice
        e22.setInt(11, Int64(lineInt.y))                    // kCGScrollWheelEventDeltaAxis1
        e22.setInt(96, Int64(point.y))                      // kCGScrollWheelEventPointDeltaAxis1
        e22.setInt(93, EventUtility.fixedScrollDelta(line.y)) // kCGScrollWheelEventFixedPtDeltaAxis1
        e22.setInt(12, Int64(lineInt.x))                    // kCGScrollWheelEventDeltaAxis2
        e22.setInt(97, Int64(point.x))                      // kCGScrollWheelEventPointDeltaAxis2
        e22.setInt(94, EventUtility.fixedScrollDelta(line.x)) // kCGScrollWheelEventFixedPtDeltaAxis2
        e22.setInt(99, phase.rawValue)                      // scroll phase
        e22.setInt(123, Int64(momentumPhase.rawValue))      // momentum phase
        e22.timestamp = eventTs
        e22.post(tap: .cgSessionEventTap)

        if phase != .undefined {
            guard let e29 = CGEvent(source: nil) else { return }
            e29.setInt(55, 29)                              // NSEventTypeGesture
            e29.setInt(110, 6)                              // subtype kIOHIDEventTypeScroll
            var dxGesture = gesture.x
            var dyGesture = gesture.y
            if dxGesture == 0 { dxGesture = -0.0 }
            if dyGesture == 0 { dyGesture = -0.0 }
            e29.setDouble(116, dxGesture)
            e29.setDouble(119, dyGesture)
            e29.setInt(132, phase.rawValue)
            e29.timestamp = eventTs
            e29.post(tap: .cgSessionEventTap)
        }
    }
}
