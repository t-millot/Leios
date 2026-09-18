// Modifiers.swift
// Leios Engine — keyboard modifier flags (listen-only tap or on-demand query) and held-button modifiers.
// Ports Helper/Core/Modifiers/Modifiers.m and ButtonModifiers.m. Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics

struct ButtonModifier: Equatable, Hashable {
    let button: Int
    let level: Int
}

struct ModifierState: Equatable, Hashable {
    var keyboardFlags: UInt64 = 0
    /// Ordered by press time.
    var buttons: [ButtonModifier] = []
}

final class Modifiers {

    /// Only bits 16–23 are modifier bits; caps lock is ignored.
    static let keyboardMask: UInt64 = 0xFF0000 & ~UInt64(CGEventFlags.maskAlphaShift.rawValue)

    private var flagsTap: EventTap?
    private let runLoop: CFRunLoop
    private(set) var state = ModifierState()
    private(set) var isActivelyListening = false

    /// Called on the engine thread whenever keyboard flags (while listening) or button modifiers change.
    var onChange: ((ModifierState) -> Void)?
    /// Called for each active button modifier when a modification has been used (so its click cycle is killed).
    var onButtonModifierUsed: ((ButtonModifier) -> Void)?

    init(runLoop: CFRunLoop) {
        self.runLoop = runLoop
    }

    static func flags(from event: CGEvent?) -> UInt64 {
        let raw = EventUtility.modifierFlags(event: event).rawValue
        return raw & keyboardMask
    }

    // MARK: Keyboard

    /// Active listening runs a listen-only flagsChanged tap so `onChange` fires on every modifier press.
    func setKeyboardListening(_ on: Bool) {
        if on && flagsTap == nil {
            flagsTap = EventTap(name: "flags", options: .listenOnly, mask: CGEventMask(1 << CGEventType.flagsChanged.rawValue), runLoop: runLoop) { [weak self] _, _, event in
                self?.handleFlagsChanged(event)
                return Unmanaged.passUnretained(event)
            }
        }
        isActivelyListening = on
        flagsTap?.enable(on)
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let flags = Modifiers.flags(from: event)
        guard flags != state.keyboardFlags else { return }
        state.keyboardFlags = flags
        onChange?(state)
    }

    /// The current modifier state; refreshes keyboard flags on demand unless actively listening.
    func current(event: CGEvent?) -> ModifierState {
        if !isActivelyListening {
            state.keyboardFlags = Modifiers.flags(from: event)
        }
        return state
    }

    // MARK: Buttons

    func buttonModifierChanged(button: Int, level: Int, down: Bool) {
        var changed = false
        if down {
            state.buttons.append(ButtonModifier(button: button, level: level))
            changed = true
        } else {
            let before = state.buttons.count
            state.buttons.removeAll { $0.button == button }
            changed = state.buttons.count != before
        }
        if changed { onChange?(state) }
    }

    func killButtonModifier(_ button: Int) {
        buttonModifierChanged(button: button, level: 0, down: false)
    }

    /// Notify active button modifiers that they have had an effect.
    func handleModificationHasBeenUsed() {
        for m in state.buttons {
            onButtonModifierUsed?(m)
        }
    }

    func invalidate() {
        flagsTap?.invalidate()
        flagsTap = nil
        isActivelyListening = false
    }
}
