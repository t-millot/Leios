// DragOutputs.swift
// MousePilot Engine — the two drag gesture outputs.
// Ports ModifiedDragOutputTwoFingerSwipe.m and ModifiedDragOutputThreeFingerSwipe.m. Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics
import QuartzCore
import CPrivateShim
import MousePilotShared

/// Simulates a two-finger trackpad swipe: scroll anywhere, swipe between pages, Mail swipe actions.
final class TwoFingerSwipeOutput: DragOutput, EmergencyCleanable {

    private unowned let thread: EngineThread
    private let gestureSim: GestureScrollSimulator
    private let pointerFreeze: PointerFreeze
    private let scroll: ScrollController
    private let smoothingAnimator: TouchAnimator
    private let lockPointer: () -> Bool

    private var eventPhase: IOHIDPhase = .undefined
    private var shouldStartMomentumScroll = false
    private var watchdog: CFRunLoopTimer?

    init(thread: EngineThread, clockPool: FrameClockPool, gestureSim: GestureScrollSimulator, pointerFreeze: PointerFreeze, scroll: ScrollController, lockPointer: @escaping () -> Bool) {
        self.thread = thread
        self.gestureSim = gestureSim
        self.pointerFreeze = pointerFreeze
        self.scroll = scroll
        self.smoothingAnimator = TouchAnimator(clockPool: clockPool)
        self.lockPointer = lockPointer
        pointerFreeze.makeCursorSettable()
    }

    func initialize(drag: ModifiedDrag) {
        scroll.reset()
    }

    func becameInUse(drag: ModifiedDrag) {
        if lockPointer() {
            pointerFreeze.freezePointer(at: drag.usageOrigin)
        } else {
            pointerFreeze.freezeEventDispatchPoint(at: drag.usageOrigin)
        }
        smoothingAnimator.resetSubPixelator()
        smoothingAnimator.link(to: EventUtility.display(at: drag.usageOrigin) ?? CGMainDisplayID())
    }

    func mouseInput(drag: ModifiedDrag, dx: Double, dy: Double, event: CGEvent) {
        let twoFingerScale = 1.0
        let firstCallback = drag.firstCallback
        let natural = drag.naturalDirection
        // Smooth the raw deltas over ~3 frames so apps computing their own momentum see regular timing.
        smoothingAnimator.start(params: { valueLeft, _, _, _ in
            let current = Vector(x: dx * twoFingerScale, y: dy * twoFingerScale)
            let combined = added(current, valueLeft)
            if firstCallback { self.eventPhase = .began }
            if magnitude(combined) == 0 { return .skip }
            return AnimatorStartParams(doStart: true, duration: 3.0 / 60.0, vector: combined, curve: ScrollConfig.linearCurve)
        }, callback: { [self] deltaVec, animatorPhase, _ in
            if animatorPhase == .end {
                if shouldStartMomentumScroll {
                    gestureSim.postGestureScroll(dx: 0, dy: 0, phase: .ended, autoMomentumScroll: true, invertedFromDevice: natural)
                }
                shouldStartMomentumScroll = false
                return
            }
            if animatorPhase == .canceled { return }
            gestureSim.postGestureScroll(dx: Int64(deltaVec.x), dy: Int64(deltaVec.y), phase: eventPhase, autoMomentumScroll: true, invertedFromDevice: natural)
            eventPhase = .changed
        })
    }

    func deactivate(drag: ModifiedDrag, cancel: Bool) {
        let natural = drag.naturalDirection
        if cancel {
            if smoothingAnimator.isRunning { smoothingAnimator.cancel() }
            gestureSim.postGestureScroll(dx: 0, dy: 0, phase: .ended, autoMomentumScroll: true, invertedFromDevice: natural)
            gestureSim.stopMomentumScroll()
            pointerFreeze.unfreeze()
            return
        }

        // Unfreeze only once momentum scrolling has been started, so the momentum lands in the view under the frozen pointer.
        cancelWatchdog()
        gestureSim.onMomentumStarted = { [weak self] in
            guard let self else { return }
            self.cancelWatchdog()
            self.pointerFreeze.unfreeze()
        }
        if smoothingAnimator.isRunning {
            shouldStartMomentumScroll = true
        } else {
            gestureSim.postGestureScroll(dx: 0, dy: 0, phase: .ended, autoMomentumScroll: true, invertedFromDevice: natural)
        }
        if pointerFreeze.isFrozen {
            watchdog = thread.scheduleTimer(after: 0.5) { [weak self] in
                guard let self else { return }
                self.gestureSim.onMomentumStarted = nil
                self.pointerFreeze.unfreeze()
            }
        }
    }

    private func cancelWatchdog() {
        if let w = watchdog { CFRunLoopTimerInvalidate(w) }
        watchdog = nil
    }

    func emergencyCleanup() {
        cancelWatchdog()
        pointerFreeze.emergencyUnfreeze()
    }
}

/// Simulates a three-finger trackpad swipe: Spaces horizontally, Mission Control / App Exposé vertically.
final class ThreeFingerSwipeOutput: DragOutput, EmergencyCleanable {

    private let touchSim: TouchSimulator
    private let pointerFreeze: PointerFreeze
    private let lockPointer: () -> Bool
    private var numberOfSpaces = 1
    private var screenSize = CGSize(width: 1920, height: 1080)

    init(touchSim: TouchSimulator, pointerFreeze: PointerFreeze, lockPointer: @escaping () -> Bool) {
        self.touchSim = touchSim
        self.pointerFreeze = pointerFreeze
        self.lockPointer = lockPointer
    }

    func initialize(drag: ModifiedDrag) {}

    func becameInUse(drag: ModifiedDrag) {
        // Count spaces (full-screen spaces appear twice in the list).
        if let spaces = CGSCopySpaces(CGSMainConnectionID(), Int32(kCGSSpaceIncludesUser.rawValue | kCGSSpaceIncludesOthers.rawValue | kCGSSpaceIncludesCurrent.rawValue))?.takeRetainedValue() as? [AnyHashable] {
            numberOfSpaces = max(1, Set(spaces).count)
        }
        let display = EventUtility.display(at: drag.usageOrigin) ?? CGMainDisplayID()
        screenSize = CGDisplayBounds(display).size
        if lockPointer() {
            pointerFreeze.freezePointer(at: drag.usageOrigin)
        }
    }

    func mouseInput(drag: ModifiedDrag, dx: Double, dy: Double, event: CGEvent) {
        // Scale so horizontal swipes follow the pointer exactly.
        let originOffsetForOneSpace = numberOfSpaces == 1 ? 2.0 : 1.0 + (1.0 / Double(numberOfSpaces - 1))
        let spaceSeparatorWidth = 63.0
        let scaleH = originOffsetForOneSpace / (screenSize.width + spaceSeparatorWidth)
        let scaleV = 1.0 / screenSize.height
        let phase: IOHIDPhase = drag.firstCallback ? .began : .changed
        if drag.usageAxis == .horizontal {
            touchSim.postDockSwipe(delta: -dx * scaleH, type: .horizontal, phase: phase, invertedFromDevice: drag.naturalDirection)
        } else if drag.usageAxis == .vertical {
            touchSim.postDockSwipe(delta: dy * scaleV, type: .vertical, phase: phase, invertedFromDevice: drag.naturalDirection)
        }
    }

    func deactivate(drag: ModifiedDrag, cancel: Bool) {
        let type: DockSwipeType = drag.usageAxis == .horizontal ? .horizontal : .vertical
        touchSim.postDockSwipe(delta: 0, type: type, phase: cancel ? .cancelled : .ended, invertedFromDevice: drag.naturalDirection)
        if lockPointer() {
            pointerFreeze.unfreeze()
        }
    }

    func emergencyCleanup() {
        pointerFreeze.emergencyUnfreeze()
    }
}
