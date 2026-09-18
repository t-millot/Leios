// SwitchMaster.swift
// Leios Engine — decides which event taps run, so unused input paths cost nothing.
// Simplified port of Helper/Core/Coordinate/SwitchMaster.swift. Derived from Mac Mouse Fix, MMF License.

import Foundation
import LeiosShared

final class SwitchMaster {

    unowned let subsystems: EngineSubsystems

    init(subsystems: EngineSubsystems) {
        self.subsystems = subsystems
    }

    private var config: LeiosConfig { subsystems.config }

    /// Gating covers the global settings *and* every app profile: the tap has to be armed before the
    /// app under the pointer is known, so one profile that modifies scrolling arms it for everything.
    private var gating: ScrollGating { subsystems.scrollGating }

    /// Scrolling is modified regardless of modifiers.
    private var defaultModifiesScroll: Bool { gating.modifiesByDefault }

    private var keyboardScrollModsConfigured: Bool { gating.anyModifierConfigured }

    /// Re-evaluates every tap. Call on start, config change, modifier change and kill-switch change.
    func reevaluate() {
        let general = config.general
        let modifierState = subsystems.modifiers.state

        // Keyboard flags tap: only needed to *toggle* the scroll tap when nothing else modifies scrolling.
        let listenForFlags = general.scrollingEnabled && keyboardScrollModsConfigured && !defaultModifiesScroll
        subsystems.modifiers.setKeyboardListening(listenForFlags)

        // Scroll tap. The held flags are tested against every modifier map in play, not just the
        // global one — an app profile may put a role on a key the global settings leave unused.
        let anyKbMod = gating.modifierMaps.contains { !ScrollModifiers.modifications(forFlags: modifierState.keyboardFlags, settings: $0).isEmpty }
        let scrollOn = general.scrollingEnabled && (defaultModifiesScroll || anyKbMod)
        subsystems.scroll.setReceiving(scrollOn)

        // Buttons. A capture armed by the settings app needs the tap even when nothing is mapped,
        // and even when the buttons kill switch is off — it only reports presses, it never acts on them.
        let buttonsOn = subsystems.buttons.isCapturing || (general.buttonsEnabled && subsystems.remapTable.anyButtonMapped)
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
