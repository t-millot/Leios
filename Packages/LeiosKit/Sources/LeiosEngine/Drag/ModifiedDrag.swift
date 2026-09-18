// ModifiedDrag.swift
// Leios Engine — "hold a button and move the mouse" gesture state machine.
// Ports Helper/Core/Drag/ModifiedDrag.m. Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics
import QuartzCore
import LeiosShared

protocol DragOutput: AnyObject {
    func initialize(drag: ModifiedDrag)
    func becameInUse(drag: ModifiedDrag)
    func mouseInput(drag: ModifiedDrag, dx: Double, dy: Double, event: CGEvent)
    func deactivate(drag: ModifiedDrag, cancel: Bool)
}

final class ModifiedDrag {

    enum ActivationState {
        case none, initialized, inUse
    }

    /// Movement (px) before the drag becomes "in use".
    let usageThreshold = 7.0

    private unowned let thread: EngineThread
    private let modifiers: Modifiers
    private var tap: EventTap?
    private var outputs: [MouseDragGesture: DragOutput] = [:]
    private var output: DragOutput?

    private(set) var gesture: MouseDragGesture?
    private(set) var activationState: ActivationState = .none
    private(set) var origin: CGPoint = .zero
    private(set) var originOffset: Vector = .zero
    private(set) var usageOrigin: CGPoint = .zero
    private(set) var usageAxis: MFAxis = .none
    private(set) var firstCallback = false
    /// Content follows the mouse movement (System Settings "natural scrolling").
    private(set) var naturalDirection = true

    var isArmed: Bool { activationState != .none }

    init(thread: EngineThread, modifiers: Modifiers) {
        self.thread = thread
        self.modifiers = modifiers
    }

    func setOutput(_ output: DragOutput, for gesture: MouseDragGesture) {
        outputs[gesture] = output
    }

    func createTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
        tap = EventTap(name: "drag", mask: mask, runLoop: thread.runLoop) { [unowned self] _, _, event in
            self.handle(event)
        }
    }

    // MARK: Arm / disarm

    func initialize(gesture: MouseDragGesture) {
        thread.assertOnEngineThread()
        if activationState == .inUse {
            return
        }
        // `SwitchMaster.reevaluate()` re-arms on every modifier change, so a keyboard modifier pressed
        // while a drag button is held used to land here again and re-run the arming: that resets the
        // accumulated offset (moving the usage threshold) and re-runs the output's `initialize`, which
        // for a two-finger swipe cancels whatever scroll animation is in flight.
        if activationState == .initialized && self.gesture == gesture {
            return
        }
        guard let output = outputs[gesture] else {
            Log.drag.error("No output for drag gesture \(gesture.rawValue)")
            return
        }
        self.gesture = gesture
        self.output = output
        origin = EventUtility.roundedPointerLocation()
        originOffset = .zero
        activationState = .initialized
        output.initialize(drag: self)
        tap?.enable(true)
    }

    func deactivate(cancel: Bool) {
        thread.assertOnEngineThread()
        if activationState == .none { return }
        if activationState == .inUse {
            output?.deactivate(drag: self, cancel: cancel)
        }
        activationState = .none
        tap?.enable(false)
    }

    func invalidate() {
        deactivate(cancel: true)
        tap?.invalidate()
        tap = nil
    }

    func emergencyCleanup() {
        for o in outputs.values {
            (o as? EmergencyCleanable)?.emergencyCleanup()
        }
    }

    // MARK: Tap

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let dx = event.getIntegerValueField(.mouseEventDeltaX)
        let dy = event.getIntegerValueField(.mouseEventDeltaY)
        if (dx != 0 || dy != 0), tap?.isEnabled == true {
            originOffset.x += Double(dx)
            originOffset.y += Double(dy)
            switch activationState {
            case .none:
                break
            case .initialized:
                handleWhileInitialized(event: event)
            case .inUse:
                handleWhileInUse(dx: Double(dx), dy: Double(dy), event: event)
            }
        }
        // Never swallow: turn dragged events into mouse-moved so apps don't see a button drag.
        event.type = .mouseMoved
        return Unmanaged.passUnretained(event)
    }

    private func handleWhileInitialized(event: CGEvent) {
        let ofs = originOffset
        if max(abs(ofs.x), abs(ofs.y)) > usageThreshold {
            usageOrigin = EventUtility.roundedPointerLocation(event: event)
            usageAxis = abs(ofs.x) < abs(ofs.y) ? .vertical : .horizontal
            activationState = .inUse
            firstCallback = true
            if let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool {
                naturalDirection = natural
            } else {
                naturalDirection = true
            }
            output?.becameInUse(drag: self)
            modifiers.handleModificationHasBeenUsed()
        }
    }

    private func handleWhileInUse(dx: Double, dy: Double, event: CGEvent) {
        var dx = dx
        var dy = dy
        if !naturalDirection {
            dx = -dx
            dy = -dy
        }
        output?.mouseInput(drag: self, dx: dx, dy: dy, event: event)
        firstCallback = false
    }
}

protocol EmergencyCleanable: AnyObject {
    func emergencyCleanup()
}
