// GeneralSettingsView.swift
// MousePilot — general options.

import SwiftUI
import MousePilotShared

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Show menu bar item", isOn: $model.config.general.showMenuBarItem)
                Toggle("Lock pointer during drag gestures", isOn: $model.config.general.lockPointerDuringDrag)
            }
            Section("Kill Switches") {
                Toggle("Scrolling enabled", isOn: $model.config.general.scrollingEnabled)
                Toggle("Buttons enabled", isOn: $model.config.general.buttonsEnabled)
            }
            Section {
                Text("MousePilot's engine is derived from the open-source project Mac Mouse Fix by Noah Nuebling (MMF License).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
