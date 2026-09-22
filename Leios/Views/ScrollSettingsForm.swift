// ScrollSettingsForm.swift
// Leios — the scroll settings controls, shared by the global tab and each app profile.

import SwiftUI
import LeiosShared

struct ScrollSettingsForm: View {
    let source: ScrollFieldSource

    private let modifierChoices: [(String, UInt64)] = [
        ("None", 0),
        ("⇧ Shift", LeiosConstants.ModifierFlag.shift),
        ("⌃ Control", LeiosConstants.ModifierFlag.control),
        ("⌥ Option", LeiosConstants.ModifierFlag.option),
        ("⌘ Command", LeiosConstants.ModifierFlag.command),
    ]

    /// Read in `body` so SwiftUI registers the dependency on `model.config` for the whole screen,
    /// not just for whichever control happens to read its binding first.
    private var effective: ScrollSettings { source.effective }

    /// The toggle and the slider are two views of one setting, pinned and reverted together on
    /// an app profile.
    private var speed: Binding<ScrollSpeed> { source.binding(\.scrollSpeed, \.scrollSpeed) }

    var body: some View {
        Form {
            Section("Smooth Scrolling") {
                Picker(selection: source.binding(\.smoothness, \.smoothness)) {
                    ForEach(ScrollSettings.Smoothness.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: {
                    label("Smoothness", \.smoothness)
                }
                .pickerStyle(.segmented)
                if effective.smoothness == .high {
                    Toggle(isOn: source.binding(\.trackpadSimulation, \.trackpadSimulation)) {
                        label("Trackpad simulation (momentum, swipe to navigate)", \.trackpadSimulation)
                    }
                }
                // A profile's revert button for Speed sits next to "Speed", and moves up here only
                // while that row is hidden, so there is always exactly one.
                Toggle(isOn: speed.usesSystem) {
                    if effective.speed == .system {
                        label("Use macOS scroll speed", \.scrollSpeed)
                    } else {
                        Text("Use macOS scroll speed").fontWeight(source.isOverridden(\.scrollSpeed) ? .semibold : .regular)
                    }
                }
                // Both shape Leios's own acceleration curve, which macOS speed replaces.
                if effective.speed != .system {
                    LabeledContent {
                        Slider(value: speed.level, in: 0...1, step: 0.1) {
                            Text("Speed")
                        } minimumValueLabel: {
                            Text("Low")
                        } maximumValueLabel: {
                            Text("High")
                        }
                        .labelsHidden()
                    } label: {
                        label("Speed", \.scrollSpeed)
                    }
                    Toggle(isOn: source.binding(\.precise, \.precise)) {
                        label("Precise (slower for small movements)", \.precise)
                    }
                }
                Toggle(isOn: source.binding(\.reverseDirection, \.reverseDirection)) {
                    label("Reverse scroll direction", \.reverseDirection)
                }
            }
            Section("Keyboard Modifiers") {
                if source.isProfile {
                    // All four at once: they are mutually exclusive, so a half-inherited set could
                    // put two roles on the same key.
                    Toggle("Use custom modifiers for this app", isOn: customModifiers)
                }
                Group {
                    modifierPicker("Scroll horizontally", \.horizontal)
                    modifierPicker("Quick scroll", \.quick)
                    modifierPicker("Precise scroll", \.precise)
                    modifierPicker("Zoom in / out", \.zoom)
                }
                // Only the pickers — the toggle above them must stay live, or it would disable itself.
                .disabled(source.isProfile && !source.isOverridden(\.modifiers))
            }
            if source.isProfile {
                // In the form rather than under it: a caption pinned below the form would be a
                // bar the form scrolls under, and this line is a footnote, not chrome.
                Section {
                    Text("App settings apply to scrolling only. Button and drag gestures always use the global settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Slides the Speed and Precise rows in and out. It has to be this modifier: a grouped Form
        // inserts and removes rows instantly under `withAnimation` or an animated binding, which
        // was measured by recording the window, not assumed.
        .animation(.default, value: effective.speed == .system)
    }

    /// A field's label, with a revert button on an app profile once the field has been pinned.
    /// The button sits next to the label rather than the control, so the form keeps its columns.
    @ViewBuilder
    private func label<V>(_ title: String, _ override: WritableKeyPath<ScrollOverrides, V?>) -> some View {
        if source.isProfile {
            let overridden = source.isOverridden(override)
            HStack(spacing: 4) {
                Text(title).fontWeight(overridden ? .semibold : .regular)
                Button { source.clear(override) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Use the global setting")
                .opacity(overridden ? 1 : 0)
                .disabled(!overridden)
                .accessibilityHidden(!overridden)
            }
        } else {
            Text(title)
        }
    }

    private var customModifiers: Binding<Bool> {
        Binding(
            get: { source.isOverridden(\.modifiers) },
            set: { on in
                if on {
                    source.binding(\.modifiers, \.modifiers).wrappedValue = source.model.config.scroll.modifiers
                } else {
                    source.clear(\.modifiers)
                }
            })
    }

    private func modifierPicker(_ title: String, _ keyPath: WritableKeyPath<ScrollModifierFlags, UInt64>) -> some View {
        let modifiers = source.binding(\.modifiers, \.modifiers)
        let binding = Binding<UInt64>(
            get: { modifiers.wrappedValue[keyPath: keyPath] },
            set: { newValue in
                var mods = modifiers.wrappedValue
                // A modifier can only be used once.
                if newValue != 0 {
                    for kp in [\ScrollModifierFlags.horizontal, \.quick, \.precise, \.zoom] where kp != keyPath && mods[keyPath: kp] == newValue {
                        mods[keyPath: kp] = 0
                    }
                }
                mods[keyPath: keyPath] = newValue
                modifiers.wrappedValue = mods
            })
        return Picker(title, selection: binding) {
            ForEach(modifierChoices, id: \.1) { Text($0.0).tag($0.1) }
        }
    }
}
