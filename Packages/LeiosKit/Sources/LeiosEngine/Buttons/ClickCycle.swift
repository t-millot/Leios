// ClickCycle.swift
// Leios Engine — click / hold / double-click state machine. Ports Helper/Core/Buttons/ClickCycle.swift with the
// force-unwrap crash fixed and timers on the engine run loop. Derived from Mac Mouse Fix, MMF License.

import Foundation

final class ClickCycle {

    enum TriggerPhase {
        case press, hold, levelExpired, release, releaseFromHold
    }

    typealias ReleaseCallback = () -> Void
    typealias TriggerCallback = (_ phase: TriggerPhase, _ clickLevel: Int, _ device: UInt64, _ button: Int, _ onRelease: inout [ReleaseCallback]) -> Void

    private enum PressState { case down, up, held }

    private struct State {
        var device: UInt64
        var button: Int
        var pressState: PressState
        var clickLevel: Int
        var downTimer: CFRunLoopTimer?
        var upTimer: CFRunLoopTimer?
    }

    /// Press-and-hold threshold.
    let holdInterval: TimeInterval = 0.25
    /// Double-click window.
    let levelExpiryInterval: TimeInterval = 0.26

    private unowned let thread: EngineThread
    private var state: State?
    private var releaseCallbacks: [Int: [ReleaseCallback]] = [:]

    init(thread: EngineThread) {
        self.thread = thread
    }

    func kill() {
        if let t = state?.downTimer { CFRunLoopTimerInvalidate(t) }
        if let t = state?.upTimer { CFRunLoopTimerInvalidate(t) }
        state = nil
    }

    func isActive(device: UInt64, button: Int) -> Bool {
        guard let s = state else { return false }
        return s.device == device && s.button == button
    }

    func isActive(button: Int) -> Bool {
        state?.button == button
    }

    func waitingForRelease(button: Int) -> Bool {
        releaseCallbacks[button] != nil
    }

    func handleClick(device: UInt64, button: Int, down: Bool, maxClickLevel: Int, trigger: @escaping TriggerCallback) {
        if !down, let callbacks = releaseCallbacks[button] {
            releaseCallbacks[button] = nil
            for c in callbacks { c() }
        }

        if down {
            let cycleIsDead = state == nil
            var buttonIsDifferent = false
            if let s = state {
                buttonIsDifferent = button != s.button || device != s.device
            }
            if cycleIsDead || buttonIsDifferent {
                kill()
                state = State(device: device, button: button, pressState: .down, clickLevel: 0)
            }
            state!.clickLevel = Math.intCycle(x: state!.clickLevel + 1, lower: 1, upper: maxClickLevel)
        }

        let lonelyRelease = !down && (state == nil || state!.device != device || state!.button != button)
        if lonelyRelease { return }

        let releaseFromHold = !down && state?.pressState == .held
        let clickLevel = state!.clickLevel

        if down {
            var c: [ReleaseCallback] = []
            trigger(.press, clickLevel, device, button, &c)
            if !c.isEmpty { releaseCallbacks[button, default: []].append(contentsOf: c) }
        } else {
            callTrigger(trigger, releaseFromHold ? .releaseFromHold : .release, clickLevel, device, button)
        }

        if releaseFromHold {
            kill()
            return
        }
        guard state != nil else { return }

        if down {
            if let t = state?.upTimer { CFRunLoopTimerInvalidate(t) }
            state?.downTimer = thread.scheduleTimer(after: holdInterval) { [weak self] in
                guard let self, let s = self.state, s.device == device, s.button == button else { return }
                var c: [ReleaseCallback] = []
                trigger(.hold, s.clickLevel, device, button, &c)
                if !c.isEmpty { self.releaseCallbacks[button, default: []].append(contentsOf: c) }
                self.state?.pressState = .held
                if let t = self.state?.upTimer { CFRunLoopTimerInvalidate(t) }
            }
            state?.upTimer = thread.scheduleTimer(after: levelExpiryInterval) { [weak self] in
                guard let self, let s = self.state, s.device == device, s.button == button else { return }
                self.callTrigger(trigger, .levelExpired, s.clickLevel, device, button)
                self.kill()
            }
        } else {
            if let t = state?.downTimer { CFRunLoopTimerInvalidate(t) }
        }
    }

    private func callTrigger(_ trigger: TriggerCallback, _ phase: TriggerPhase, _ level: Int, _ device: UInt64, _ button: Int) {
        var garbage: [ReleaseCallback] = []
        trigger(phase, level, device, button, &garbage)
        assert(garbage.isEmpty)
    }
}
