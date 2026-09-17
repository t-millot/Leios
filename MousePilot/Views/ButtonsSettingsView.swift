// ButtonsSettingsView.swift
// MousePilot — per-button click / hold / drag assignments.

import SwiftUI
import MousePilotShared

struct ButtonsSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var highlighted: Int?
    @State private var highlightTask: Task<Void, Never>?

    private var mappedButtons: [Int] { model.config.buttons.keys.sorted() }

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { scroller in
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
                                    .foregroundStyle(highlighted == button ? Color.accentColor : .primary)
                                Spacer()
                                Button(role: .destructive) { model.config.buttons[button] = nil } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(buttonName(button))")
                            }
                        }
                        .id(button)
                    }
                }
                .formStyle(.grouped)
                .onChange(of: highlighted) { _, new in
                    guard let new else { return }
                    withAnimation { scroller.scrollTo(new, anchor: .center) }
                }
            }
            ButtonCaptureZone(onCapture: capture,
                              armHelper: { await model.captureButtonFromHelper(timeout: $0) },
                              disarmHelper: { model.cancelButtonCapture() })
                .padding(.horizontal)
            HStack {
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

    /// Adds the pressed button to the config, or reports why it can't be added.
    private func capture(_ button: Int) -> ButtonCaptureResult {
        let result = ButtonCaptureResult.classify(button: button,
                                                  isAlreadyMapped: model.config.buttons[button] != nil)
        switch result {
        case .added:
            model.config.buttons[button] = ButtonMapping()
            highlight(button)
        case .alreadyMapped:
            highlight(button)
        case .primaryButton, .outOfRange:
            break
        }
        return result
    }

    private func highlight(_ button: Int) {
        highlighted = button
        highlightTask?.cancel()
        highlightTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            highlighted = nil
        }
    }

    private func buttonName(_ button: Int) -> String { MouseButtonNaming.name(button) }

    private func actionPicker(_ title: String, button: Int, _ keyPath: WritableKeyPath<ButtonMapping, Action?>) -> some View {
        @Bindable var model = model
        let binding = Binding<Action?>(
            get: { model.config.buttons[button]?[keyPath: keyPath] },
            set: { model.config.buttons[button, default: ButtonMapping()][keyPath: keyPath] = $0 })
        return Picker(title, selection: binding) {
            Text("None").tag(Action?.none)
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
            Text("None").tag(MouseDragGesture?.none)
            ForEach(MouseDragGesture.allCases, id: \.self) { g in
                Text(g.displayName).tag(Optional(g))
            }
        }
    }
}
