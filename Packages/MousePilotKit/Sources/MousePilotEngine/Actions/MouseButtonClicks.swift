// MouseButtonClicks.swift
// MousePilot Engine — synthesizes mouse button clicks (ports ModificationUtility.postMouseButtonClicks:).
// Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics

enum MouseButtonClicks {

    private static func eventTypes(button: Int, down: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case 1: return (down ? .leftMouseDown : .leftMouseUp, .left)
        case 2: return (down ? .rightMouseDown : .rightMouseUp, .right)
        default: return (down ? .otherMouseDown : .otherMouseUp, CGMouseButton(rawValue: UInt32(button - 1)) ?? .center)
        }
    }

    static func post(button: Int, count: Int) {
        let loc = EventUtility.pointerLocation()
        let (downType, cgButton) = eventTypes(button: button, down: true)
        let (upType, _) = eventTypes(button: button, down: false)
        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: loc, mouseButton: cgButton),
              let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: loc, mouseButton: cgButton) else { return }
        var clickLevel = 1
        while clickLevel <= max(count, 1) {
            downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickLevel))
            upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickLevel))
            downEvent.post(tap: .cgSessionEventTap)
            upEvent.post(tap: .cgSessionEventTap)
            clickLevel += 1
        }
    }

    static func post(button: Int, down: Bool) {
        let loc = EventUtility.pointerLocation()
        let (type, cgButton) = eventTypes(button: button, down: down)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cgSessionEventTap)
    }
}
