// ButtonInputReceiver.swift
// MousePilot Engine — CGEventTap for mouse buttons 3+ (ports Helper/Core/Buttons/ButtonInputReceiver.m).
// Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics

final class ButtonInputReceiver {

    private unowned let thread: EngineThread
    private var tap: EventTap?
    var buttons: Buttons?

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

    var isReceiving: Bool { tap?.isEnabled ?? false }

    func setReceiving(_ on: Bool) {
        tap?.enable(on)
    }

    func invalidate() {
        tap?.invalidate()
        tap = nil
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
        let down = event.getIntegerValueField(.mouseEventPressure) != 0
        if button == 1 || button == 2 { return Unmanaged.passUnretained(event) }
        guard let buttons else { return Unmanaged.passUnretained(event) }
        // Identify the device by the IORegistry sender id (0 for synthetic events).
        let device = event.senderID
        let swallow = buttons.handleInput(device: device, button: button, down: down, event: event)
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
