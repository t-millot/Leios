// GeneralSettingsView.swift
// Leios — general options.

import SwiftUI
import LeiosShared

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Show menu bar item", isOn: $model.config.general.showMenuBarItem)
                Toggle("Lock pointer during drag gestures", isOn: $model.config.general.lockPointerDuringDrag)
            }
            Section("iCloud") {
                Toggle("Sync settings with iCloud", isOn: $model.syncEnabled)
                Text(model.syncState.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .noAccount = model.syncState {
                    Button("Open iCloud Settings…") { model.openICloudSettings() }
                }
            }
            Section("Kill Switches") {
                Toggle("Scrolling enabled", isOn: $model.config.general.scrollingEnabled)
                Toggle("Buttons enabled", isOn: $model.config.general.buttonsEnabled)
                Text("The kill switches and the menu bar item stay on this Mac; iCloud does not carry them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Leios's engine is derived from the open-source project Mac Mouse Fix by Noah Nuebling (MMF License).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
