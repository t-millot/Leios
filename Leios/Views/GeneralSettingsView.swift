// GeneralSettingsView.swift
// Leios — general options.

import SwiftUI
import LeiosShared

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingReset = false

    var body: some View {
        @Bindable var model = model
        @Bindable var updates = model.updates
        Form {
            Section {
                Toggle("Show menu bar item", isOn: $model.config.general.showMenuBarItem)
                Toggle("Lock pointer during drag gestures", isOn: $model.config.general.lockPointerDuringDrag)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                Toggle("Include pre-release versions", isOn: $updates.includePrereleases)
                LabeledContent("Last checked") {
                    HStack {
                        Text(lastCheckedDescription)
                            .foregroundStyle(.secondary)
                        Button("Check Now") { model.updates.checkForUpdates() }
                            .disabled(!model.updates.canCheckForUpdates)
                    }
                }
                Text("Pre-releases are beta builds, published before a version is finished. Like the kill switches, both of these stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Statistics") {
                Toggle("Collect usage statistics", isOn: $model.config.general.collectStatistics)
                Button("Reset Statistics…", role: .destructive) { confirmingReset = true }
                Text("Counting happens on this Mac while Leios is running. Like the kill switches, this switch stays here — iCloud does not carry it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("iCloud") {
                Toggle("Sync settings with iCloud", isOn: $model.syncEnabled)
                Toggle("Include usage statistics", isOn: $model.statsSyncEnabled)
                    .disabled(!model.syncEnabled)
                Text(model.syncState.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .noAccount = model.syncState {
                    Button("Open iCloud Settings…") { model.openICloudSettings() }
                }
                Text("With statistics included, the Statistics screen adds up every Mac signed in to this Apple Account. Turning it off withdraws this Mac's counts from iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Kill Switches") {
                Toggle("Scrolling enabled", isOn: $model.config.general.scrollingEnabled)
                Toggle("Buttons enabled", isOn: $model.config.general.buttonsEnabled)
                Text("The kill switches, the menu bar item and the statistics switch stay on this Mac; iCloud does not carry them.")
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
        .confirmationDialog("Reset statistics?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                Task { await model.resetStatistics() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every count Leios has kept will be discarded. This cannot be undone.")
        }
    }

    private var lastCheckedDescription: String {
        guard let date = model.updates.lastCheckDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
