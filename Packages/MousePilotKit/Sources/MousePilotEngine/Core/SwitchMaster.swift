// SwitchMaster.swift
// MousePilot Engine — decides which event taps run, so unused input paths cost nothing.
// Simplified port of Helper/Core/Coordinate/SwitchMaster.swift. Derived from Mac Mouse Fix, MMF License.

import Foundation
import MousePilotShared

final class SwitchMaster {

    unowned let subsystems: EngineSubsystems

    init(subsystems: EngineSubsystems) {
        self.subsystems = subsystems
    }

    private var config: MousePilotConfig { subsystems.config }

    /// Scrolling is modified regardless of modifiers.
    private var defaultModifiesScroll: Bool {
        let s = config.scroll
        return s.smoothness != .off || s.speed != .system || s.reverseDirection
    }

    private var keyboardScrollModsConfigured: Bool {
        config.scroll.modifiers.anyConfigured
    }

    /// Re-evaluates every tap. Call on start, config change, modifier change and kill-switch change.
    func reevaluate() {
        let general = config.general
        let modifierState = subsystems.modifiers.state

        // Keyboard flags tap: only needed to *toggle* the scroll tap when nothing else modifies scrolling.
        let listenForFlags = general.scrollingEnabled && keyboardScrollModsConfigured && !defaultModifiesScroll
        subsystems.modifiers.setKeyboardListening(listenForFlags)

        // Scroll tap
        let currentKbMod = ScrollModifiers.modifications(forFlags: modifierState.keyboardFlags, settings: config.scroll.modifiers)
        let scrollOn = general.scrollingEnabled && (defaultModifiesScroll || !currentKbMod.isEmpty)
        subsystems.scroll.setReceiving(scrollOn)

        // Buttons
        let buttonsOn = general.buttonsEnabled && subsystems.remapTable.anyButtonMapped
        subsystems.buttons.setReceiving(buttonsOn)

        // Drag
        if general.buttonsEnabled, let gesture = subsystems.remapTable.dragArmed(for: modifierState) {
            subsystems.modifiedDrag.initialize(gesture: gesture)
        } else {
            subsystems.modifiedDrag.deactivate(cancel: false)
        }

        subsystems.engine.updateStatus { s in
            s.scrollTapEnabled = scrollOn
            s.flagsTapEnabled = listenForFlags
            s.buttonTapEnabled = buttonsOn
            s.dragTapEnabled = subsystems.modifiedDrag.isArmed
        }
    }

    /// Everything off (engine stopping or Accessibility revoked).
    func disableAll() {
        subsystems.modifiers.setKeyboardListening(false)
        subsystems.scroll.setReceiving(false)
        subsystems.buttons.setReceiving(false)
        subsystems.modifiedDrag.deactivate(cancel: true)
    }
}
