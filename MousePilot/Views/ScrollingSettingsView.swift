// ScrollingSettingsView.swift
// MousePilot — scroll wheel settings.

import SwiftUI
import MousePilotShared

struct ScrollingSettingsView: View {
    @Environment(AppModel.self) private var model

    private let modifierChoices: [(String, UInt64)] = [
        ("None", 0),
        ("⇧ Shift", MPConstants.ModifierFlag.shift),
        ("⌃ Control", MPConstants.ModifierFlag.control),
        ("⌥ Option", MPConstants.ModifierFlag.option),
        ("⌘ Command", MPConstants.ModifierFlag.command),
    ]

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Smooth Scrolling") {
                Picker("Smoothness", selection: $model.config.scroll.smoothness) {
                    ForEach(ScrollSettings.Smoothness.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.config.scroll.smoothness == .high {
                    Toggle("Trackpad simulation (momentum, swipe to navigate)", isOn: $model.config.scroll.trackpadSimulation)
                }
                Picker("Speed", selection: $model.config.scroll.speed) {
                    ForEach(ScrollSettings.Speed.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.config.scroll.speed != .system {
                    Toggle("Precise (slower for small movements)", isOn: $model.config.scroll.precise)
                }
                Toggle("Reverse scroll direction", isOn: $model.config.scroll.reverseDirection)
            }
            Section("Keyboard Modifiers") {
                modifierPicker("Scroll horizontally", \.horizontal)
                modifierPicker("Quick scroll", \.quick)
                modifierPicker("Precise scroll", \.precise)
                modifierPicker("Zoom in / out", \.zoom)
            }
        }
        .formStyle(.grouped)
    }

    private func modifierPicker(_ title: String, _ keyPath: WritableKeyPath<ScrollModifierFlags, UInt64>) -> some View {
        @Bindable var model = model
        let binding = Binding<UInt64>(
            get: { model.config.scroll.modifiers[keyPath: keyPath] },
            set: { newValue in
                var mods = model.config.scroll.modifiers
                // A modifier can only be used once.
                if newValue != 0 {
                    for kp in [\ScrollModifierFlags.horizontal, \.quick, \.precise, \.zoom] where kp != keyPath && mods[keyPath: kp] == newValue {
                        mods[keyPath: kp] = 0
                    }
                }
                mods[keyPath: keyPath] = newValue
                model.config.scroll.modifiers = mods
            })
        return Picker(title, selection: binding) {
            ForEach(modifierChoices, id: \.1) { Text($0.0).tag($0.1) }
        }
    }
}
