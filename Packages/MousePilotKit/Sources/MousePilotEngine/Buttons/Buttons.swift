// Buttons.swift
// MousePilot Engine — turns click-cycle triggers into actions and button-modifier updates.
// Ports Helper/Core/Buttons/Buttons.swift (trigger→action mapping kept verbatim). Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics
import MousePilotShared

enum ActionPhase {
    case start, end, combined
}

final class Buttons {

    private let clickCycle: ClickCycle
    private let modifiers: Modifiers
    private let remapTable: RemapTable
    private let executor: ActionExecutor

    /// Whether held buttons act as modifiers (needed for drag gestures).
    var useButtonModifiers = true

    private var modifierState = ModifierState()
    private var modifications = Modification()
    private var maxClickLevel = -1

    init(thread: EngineThread, modifiers: Modifiers, remapTable: RemapTable, executor: ActionExecutor) {
        self.clickCycle = ClickCycle(thread: thread)
        self.modifiers = modifiers
        self.remapTable = remapTable
        self.executor = executor
    }

    /// Returns true if the event must be swallowed.
    func handleInput(device: UInt64, button: Int, down: Bool, event: CGEvent) -> Bool {
        let clickCycleIsActive = clickCycle.isActive(device: device, button: button)
        if down && !clickCycleIsActive {
            modifierState = modifiers.current(event: event)
            modifications = remapTable.modifications(for: modifierState)
            maxClickLevel = remapTable.maxLevel(button: button)
        }
        // `maxClickLevel` describes whichever button last started a cycle, so pressing an unmapped
        // button while a mapped one is held leaves it at 0. A release must still reach the click cycle
        // whenever *this* button's press did, or it passes through to the system with no matching
        // press and its release callbacks never run — which strands the button modifier it installed.
        // Mac Mouse Fix keeps one shared value here and has the same hole.
        let pressWasHandled = !down && (clickCycleIsActive || clickCycle.waitingForRelease(button: button))
        if maxClickLevel == 0 && !pressWasHandled {
            return false
        }

        clickCycle.handleClick(device: device, button: button, down: down, maxClickLevel: maxClickLevel) { [unowned self] triggerPhase, clickLevel, device, button, onRelease in

            if useButtonModifiers && triggerPhase == .press {
                modifiers.buttonModifierChanged(button: button, level: clickLevel, down: true)
                onRelease.append { [unowned self] in
                    modifiers.buttonModifierChanged(button: button, level: clickLevel, down: false)
                }
            }

            let (clickExists, downStateEffectExists, greaterLevelExists) = remapTable.assessMappingLandscape(button: button, level: clickLevel, modifications: modifications)

            // "Fire as early as possible, unless a longer gesture is still possible."
            var map: [ClickCycle.TriggerPhase: (ButtonTriggerDuration, ActionPhase)] = [:]
            if clickExists {
                if greaterLevelExists {
                    map[.levelExpired] = (.click, .combined)
                } else if downStateEffectExists {
                    map[.release] = (.click, .combined)
                } else {
                    map[.press] = (.click, .start)
                }
            }
            if downStateEffectExists {
                map[.hold] = (.hold, .start)
            }

            guard let (duration, startOrEnd) = map[triggerPhase],
                  let action = modifications.action(button: button, level: clickLevel, duration: duration) else {
                return
            }

            if startOrEnd == .combined {
                executor.execute(action, phase: .combined)
            } else {
                executor.execute(action, phase: .start)
                onRelease.append { [unowned self] in executor.execute(action, phase: .end) }
            }

            handleButtonHasHadDirectEffect(device: device, button: button)
            modifiers.handleModificationHasBeenUsed()
        }
        return true
    }

    func handleButtonHasHadDirectEffect(device: UInt64, button: Int) {
        if clickCycle.isActive(device: device, button: button) {
            clickCycle.kill()
        }
        if useButtonModifiers {
            modifiers.killButtonModifier(button)
        }
    }

    func handleButtonHasHadEffectAsModifier(button: Int) {
        if clickCycle.isActive(button: button) {
            clickCycle.kill()
        }
    }

    func killClickCycle() {
        clickCycle.kill()
    }
}
