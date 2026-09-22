// ButtonInputReceiver.swift
// Leios Engine — CGEventTap for mouse buttons 3+ (ports Helper/Core/Buttons/ButtonInputReceiver.m).
// Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics
import LeiosShared

final class ButtonInputReceiver {

    private unowned let thread: EngineThread
    private var tap: EventTap?
    var buttons: Buttons?
    /// Called when arming or disarming capture mode, so `SwitchMaster` can re-decide the tap state.
    var onCaptureStateChanged: (() -> Void)?

    /// Reports the next pressed button to the app instead of acting on it. See `beginCapture`.
    private var captureCompletion: ((Int) -> Void)?
    private var captureTimer: CFRunLoopTimer?
    /// Button whose release still has to be swallowed after its press was captured.
    private var swallowReleaseOf: Int?
    private var releaseTimer: CFRunLoopTimer?

    /// Longest wait for the release of a captured press before giving up on swallowing it.
    private static let releaseTimeout: TimeInterval = 5

    init(thread: EngineThread) {
        self.thread = thread
    }

    func createTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue) | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        tap = EventTap(name: "buttons", mask: mask, runLoop: thread.runLoop) { [unowned self] _, _, event in
            self.handle(event)
        }
    }

    /// True while a capture is armed or a captured button's release is still pending, which keeps
    /// the tap alive even when no button is mapped.
    var isCapturing: Bool { captureCompletion != nil || swallowReleaseOf != nil }

    func setReceiving(_ on: Bool) {
        tap?.enable(on)
    }

    func invalidate() {
        endCapture(reporting: ButtonCapture.timedOut)
        clearPendingRelease()
        tap?.invalidate()
        tap = nil
    }

    // MARK: Capture mode

    /// Swallows the next button press and reports its number to `completion` instead of acting on it.
    /// `completion` runs exactly once — with the button number, or `ButtonCapture.timedOut` when
    /// `timeout` elapses, the capture is superseded, or the engine stops.
    func beginCapture(timeout: TimeInterval, completion: @escaping (Int) -> Void) {
        thread.assertOnEngineThread()
        endCapture(reporting: ButtonCapture.timedOut)
        captureCompletion = completion
        captureTimer = thread.scheduleTimer(after: timeout) { [weak self] in
            guard let self else { return }
            self.endCapture(reporting: ButtonCapture.timedOut)
            self.captureStateChanged()
        }
        captureStateChanged()
    }

    func cancelCapture() {
        thread.assertOnEngineThread()
        endCapture(reporting: ButtonCapture.timedOut)
        captureStateChanged()
    }

    private func endCapture(reporting button: Int) {
        if let captureTimer { CFRunLoopTimerInvalidate(captureTimer) }
        captureTimer = nil
        guard let completion = captureCompletion else { return }
        captureCompletion = nil
        completion(button)
    }

    private func clearPendingRelease() {
        if let releaseTimer { CFRunLoopTimerInvalidate(releaseTimer) }
        releaseTimer = nil
        swallowReleaseOf = nil
    }

    /// Lets `SwitchMaster` re-decide the tap state on the next run-loop pass — never from inside
    /// the tap callback, which is still holding the event being handled.
    private func captureStateChanged() {
        thread.perform { [weak self] in self?.onCaptureStateChanged?() }
    }

    /// Consumes a press while capturing. Returns true when the event must be swallowed.
    private func handleWhileCapturing(button: Int, down: Bool) -> Bool {
        if down {
            guard captureCompletion != nil else { return false }
            endCapture(reporting: button)
            swallowReleaseOf = button
            releaseTimer = thread.scheduleTimer(after: Self.releaseTimeout) { [weak self] in
                guard let self else { return }
                self.clearPendingRelease()
                self.captureStateChanged()
            }
            captureStateChanged()
            Log.engine.info("Captured button \(button) for the settings app")
            return true
        }
        guard swallowReleaseOf == button else { return false }
        clearPendingRelease()
        captureStateChanged()
        return true
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
        let down = event.getIntegerValueField(.mouseEventPressure) != 0
        if button == 1 || button == 2 { return Unmanaged.passUnretained(event) }
        // Capture mode takes priority: the press is reported to the app and never reaches the system,
        // so a button that already has an assignment can be re-captured without firing its action.
        if isCapturing, handleWhileCapturing(button: button, down: down) { return nil }
        guard let buttons else { return Unmanaged.passUnretained(event) }
        // Identify the device by the IORegistry sender id (0 for synthetic events).
        let device = event.senderID
        let swallow = buttons.handleInput(device: device, button: button, down: down, event: event)
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
