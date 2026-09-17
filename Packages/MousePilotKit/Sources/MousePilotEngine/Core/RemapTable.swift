// RemapTable.swift
// MousePilot Engine — maps (modifier state, button, level, duration) → actions and drag gestures.
// Simplified replacement for Mac Mouse Fix's Remap.m / RemapSwizzler.m / RemapsAnalyzer.m, keyed by a
// `Precondition` so keyboard-modifier preconditions can be added later. Derived from Mac Mouse Fix, MMF License.

import Foundation
import MousePilotShared

enum ButtonTriggerDuration: Hashable {
    case click, hold
}

struct Precondition: Hashable {
    var keyboardFlags: UInt64 = 0
    var buttons: [ButtonModifier] = []

    var size: Int { keyboardFlags.nonzeroBitCount + buttons.count }

    /// True if this precondition is satisfied by (is a subset of) `state`.
    func isSubset(of state: ModifierState) -> Bool {
        if (state.keyboardFlags & keyboardFlags) != keyboardFlags { return false }
        // Button preconditions must be a subsequence of the pressed buttons.
        var i = 0
        for pressed in state.buttons where i < buttons.count {
            if pressed == buttons[i] { i += 1 }
        }
        return i == buttons.count
    }
}

struct ButtonLevelActions {
    var click: Action?
    var hold: Action?
}

/// The effects that apply under a given modifier state.
struct Modification {
    /// button → level → actions
    var buttonActions: [Int: [Int: ButtonLevelActions]] = [:]
    var drag: MouseDragGesture?

    func action(button: Int, level: Int, duration: ButtonTriggerDuration) -> Action? {
        guard let a = buttonActions[button]?[level] else { return nil }
        return duration == .click ? a.click : a.hold
    }
}

final class RemapTable {

    private(set) var table: [Precondition: Modification] = [:]
    private(set) var anyButtonMapped = false
    private(set) var anyDragMapped = false

    init(buttons: [Int: ButtonMapping]) {
        update(buttons: buttons)
    }

    func update(buttons: [Int: ButtonMapping]) {
        var table: [Precondition: Modification] = [:]
        var base = Modification()
        anyButtonMapped = false
        anyDragMapped = false
        for (button, mapping) in buttons {
            guard button >= 1 && button <= MPConstants.maxButton, !mapping.isEmpty else { continue }
            anyButtonMapped = true
            var levels = base.buttonActions[button] ?? [:]
            if let click = mapping.click { levels[1, default: ButtonLevelActions()].click = click }
            if let hold = mapping.hold { levels[1, default: ButtonLevelActions()].hold = hold }
            if let double = mapping.doubleClick { levels[2, default: ButtonLevelActions()].click = double }
            if !levels.isEmpty { base.buttonActions[button] = levels }
            if let drag = mapping.drag {
                anyDragMapped = true
                let pre = Precondition(buttons: [ButtonModifier(button: button, level: 1)])
                table[pre, default: Modification()].drag = drag
            }
        }
        table[Precondition()] = base
        self.table = table
    }

    // MARK: Queries

    /// The modification active under `state`: the unconditional button actions plus the drag of the best matching
    /// button precondition (largest, most recently pressed first).
    func modifications(for state: ModifierState) -> Modification {
        var result = table[Precondition()] ?? Modification()
        result.drag = dragArmed(for: state)
        return result
    }

    func dragArmed(for state: ModifierState) -> MouseDragGesture? {
        var best: (Precondition, MouseDragGesture)?
        for (pre, mod) in table {
            guard let drag = mod.drag, !pre.buttons.isEmpty, pre.isSubset(of: state) else { continue }
            if let b = best {
                if pre.size > b.0.size { best = (pre, drag) }
                else if pre.size == b.0.size, let last = state.buttons.last, pre.buttons.last == last { best = (pre, drag) }
            } else {
                best = (pre, drag)
            }
        }
        return best?.1
    }

    /// Highest click level that has any effect for `button` (0 → the button is unmapped and passes through).
    func maxLevel(button: Int) -> Int {
        var maxLvl = 0
        if let levels = table[Precondition()]?.buttonActions[button] {
            for (level, actions) in levels where actions.click != nil || actions.hold != nil {
                maxLvl = max(maxLvl, level)
            }
        }
        for pre in table.keys {
            for m in pre.buttons where m.button == button {
                maxLvl = max(maxLvl, m.level)
            }
        }
        return maxLvl
    }

    func isModifier(button: Int, level: Int) -> Bool {
        table.keys.contains { $0.buttons.contains(ButtonModifier(button: button, level: level)) }
    }

    /// Ports RemapsAnalyzer.assessMappingLandscape.
    func assessMappingLandscape(button: Int, level: Int, modifications: Modification) -> (clickExists: Bool, downStateEffectExists: Bool, greaterLevelExists: Bool) {
        let clickExists = modifications.action(button: button, level: level, duration: .click) != nil
        let holdExists = modifications.action(button: button, level: level, duration: .hold) != nil
        let downStateEffectExists = holdExists || isModifier(button: button, level: level)
        let greaterLevelExists = maxLevel(button: button) > level
        return (clickExists, downStateEffectExists, greaterLevelExists)
    }
}
