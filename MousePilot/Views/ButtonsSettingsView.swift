// ButtonsSettingsView.swift
// MousePilot — per-button click / hold / drag assignments.

import SwiftUI
import MousePilotShared

struct ButtonsSettingsView: View {
    @Environment(AppModel.self) private var model

    private var mappedButtons: [Int] { model.config.buttons.keys.sorted() }
    private var unmappedButtons: [Int] { (MPConstants.minButton...MPConstants.maxButton).filter { model.config.buttons[$0] == nil } }

    var body: some View {
        VStack(spacing: 8) {
            Form {
                if mappedButtons.isEmpty {
                    Text("No buttons configured.").foregroundStyle(.secondary)
                }
                ForEach(mappedButtons, id: \.self) { button in
                    Section {
                        actionPicker("Click", button: button, \.click)
                        actionPicker("Double Click", button: button, \.doubleClick)
                        actionPicker("Click and Hold", button: button, \.hold)
                        dragPicker(button: button)
                    } header: {
                        HStack {
                            Text(buttonName(button))
                            Spacer()
                            Button(role: .destructive) { model.config.buttons[button] = nil } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Menu("Add Button") {
                    ForEach(unmappedButtons, id: \.self) { button in
                        Button(buttonName(button)) { model.config.buttons[button] = ButtonMapping() }
                    }
                }
                .fixedSize()
                Menu("Presets") {
                    Button("5-button mouse") { model.config.buttons = MousePilotConfig.fiveButtonPreset }
                    Button("3-button mouse") { model.config.buttons = MousePilotConfig.threeButtonPreset }
                    Button("Clear all") { model.config.buttons = [:] }
                }
                .fixedSize()
                Spacer()
                Text("Buttons with an assignment no longer send their original click.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
    }

    private func buttonName(_ button: Int) -> String {
        switch button {
        case 3: return "Middle Button (3)"
        case 4: return "Button 4"
        case 5: return "Button 5"
        default: return "Button \(button)"
        }
    }

    private func actionPicker(_ title: String, button: Int, _ keyPath: WritableKeyPath<ButtonMapping, Action?>) -> some View {
        @Bindable var model = model
        let binding = Binding<Action?>(
            get: { model.config.buttons[button]?[keyPath: keyPath] },
            set: { model.config.buttons[button, default: ButtonMapping()][keyPath: keyPath] = $0 })
        return Picker(title, selection: binding) {
            Text("None").tag(Optional<Action>.none)
            ForEach(Action.uiChoices, id: \.self) { action in
                Text(action.displayName).tag(Optional(action))
            }
        }
    }

    private func dragPicker(button: Int) -> some View {
        @Bindable var model = model
        let binding = Binding<MouseDragGesture?>(
            get: { model.config.buttons[button]?.drag },
            set: { model.config.buttons[button, default: ButtonMapping()].drag = $0 })
        return Picker("Click and Drag", selection: binding) {
            Text("None").tag(Optional<MouseDragGesture>.none)
            ForEach(MouseDragGesture.allCases, id: \.self) { g in
                Text(g.displayName).tag(Optional(g))
            }
        }
    }
}
