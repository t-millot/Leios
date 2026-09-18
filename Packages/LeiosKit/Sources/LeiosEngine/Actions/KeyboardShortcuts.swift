// KeyboardShortcuts.swift
// Leios Engine — posts keyboard shortcuts and system-defined (media key) events.
// Ports the helpers in Helper/Core/Actions/Actions.m. Derived from Mac Mouse Fix, MMF License.

import Foundation
import AppKit
import Carbon.HIToolbox
import LeiosShared

enum KeyboardShortcuts {

    static var currentKeyboardType: UInt32 { UInt32(LMGetKbdType()) }

    static func postKeyboardShortcut(keyCode: Int, flags: UInt64) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) else { return }
        let cgFlags = CGEventFlags(rawValue: flags)
        keyDown.flags = cgFlags
        keyUp.flags = cgFlags
        // CGEventCreateKeyboardEvent may pick the wrong keyboard type with several keyboards attached.
        keyDown.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(currentKeyboardType))
        keyUp.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(currentKeyboardType))
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        // Modifier restore event
        CGEvent(source: nil)?.post(tap: .cgSessionEventTap)
    }

    /// Key down + key up with `flags` on the down event and the original flags on the up event.
    static func postKeyEvents(keyCode: Int, flags: UInt64) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) else { return }
        let originalFlags = keyDown.flags
        keyDown.flags = CGEventFlags(rawValue: flags)
        keyUp.flags = originalFlags
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    /// Media keys etc. (NSEvent type systemDefined, subtype 8).
    static func postSystemDefinedEvent(type: SystemDefinedEventType, flags: UInt64) {
        let base = (1 << 9) | (1 << 11)
        let data = base | (type.rawValue << 16)
        let downData = data
        let upData = data | (1 << 8)
        let loc = NSEvent.mouseLocation
        let mods = NSEvent.ModifierFlags(rawValue: UInt(flags))
        for d in [downData, upData] {
            let ts = ProcessInfo.processInfo.systemUptime
            if let e = NSEvent.otherEvent(with: .systemDefined, location: loc, modifierFlags: mods, timestamp: ts, windowNumber: -1, context: nil, subtype: 8, data1: d, data2: -1) {
                e.cgEvent?.post(tap: .cgSessionEventTap)
            }
        }
    }
}
