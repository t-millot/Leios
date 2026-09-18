// AppsSettingsView.swift
// Leios — per-application scroll profiles.

import SwiftUI
import LeiosShared

struct AppsSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: String?

    /// Sorted by the name the user sees, with the bundle ID breaking ties so rows never swap around.
    private var bundleIDs: [String] {
        model.config.apps.keys.sorted { a, b in
            let byName = name(a).localizedStandardCompare(name(b))
            return byName == .orderedSame ? a < b : byName == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 190)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("App settings apply to scrolling only. Button and drag gestures always use the global settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        }
        .onAppear { AppCatalog.refresh() }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(bundleIDs, id: \.self) { bundleID in
                    row(bundleID).tag(bundleID)
                }
            }
            .overlay {
                if bundleIDs.isEmpty {
                    ContentUnavailableView("No Apps", systemImage: "square.grid.2x2",
                                           description: Text("Add an app to give it its own scroll settings."))
                        .controlSize(.small)
                }
            }
            Divider()
            HStack(spacing: 0) {
                addMenu
                Button { remove() } label: { Image(systemName: "minus") }
                    .help("Remove the selected app")
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private var addMenu: some View {
        Menu {
            let running = AppCatalog.runningApps().filter { model.config.apps[$0.bundleID] == nil }
            if running.isEmpty {
                Text("No other apps are running")
            } else {
                ForEach(running, id: \.bundleID) { app in
                    Button { add(bundleID: app.bundleID, name: app.name) } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: AppCatalog.icon(forBundleID: app.bundleID)) }
                    }
                }
            }
            Divider()
            Button("Other…") {
                if let chosen = AppCatalog.chooseApplication() {
                    add(bundleID: chosen.bundleID, name: chosen.name)
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add an app")
    }

    private func row(_ bundleID: String) -> some View {
        let installed = AppCatalog.isInstalled(bundleID)
        return HStack(spacing: 6) {
            Image(nsImage: AppCatalog.icon(forBundleID: bundleID))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(name(bundleID)).lineLimit(1)
                if !installed {
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                }
            }
            .opacity(installed ? 1 : 0.6)
        }
        .help(bundleID)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, model.config.apps[selection] != nil {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(nsImage: AppCatalog.icon(forBundleID: selection))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name(selection)).font(.headline)
                        Text(selection).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
                ScrollSettingsForm(source: ScrollFieldSource(model: model, bundleID: selection))
            }
        } else {
            ContentUnavailableView("No App Selected", systemImage: "cursorarrow.motionlines",
                                   description: Text("Select an app to change how scrolling feels in it."))
        }
    }

    // MARK: Actions

    /// The name recorded when the app was added, so an app that has since been removed from disk
    /// still reads as itself rather than as a bare bundle identifier.
    private func name(_ bundleID: String) -> String {
        AppCatalog.displayName(forBundleID: bundleID) ?? model.config.apps[bundleID]?.name ?? bundleID
    }

    private func add(bundleID: String, name: String) {
        if model.config.apps[bundleID] == nil {
            model.config.apps[bundleID] = AppProfile(name: name)
        }
        selection = bundleID
    }

    private func remove() {
        guard let selection else { return }
        model.config.apps[selection] = nil
        self.selection = nil
    }
}
