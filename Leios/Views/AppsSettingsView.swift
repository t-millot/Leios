// AppsSettingsView.swift
// Leios — per-application scroll profiles: the sidebar rows under Apps, and what each one shows.

import SwiftUI
import LeiosShared

/// Shared by the sidebar and the detail panes, so a profile reads the same name in both places.
enum AppProfiles {
    /// Sorted by the name the user sees, with the bundle ID breaking ties so rows never swap around.
    static func sorted(_ apps: [String: AppProfile]) -> [String] {
        apps.keys.sorted { a, b in
            let byName = name(a, in: apps).localizedStandardCompare(name(b, in: apps))
            return byName == .orderedSame ? a < b : byName == .orderedAscending
        }
    }

    /// The name recorded when the app was added, so an app that has since been removed from disk
    /// still reads as itself rather than as a bare bundle identifier.
    static func name(_ bundleID: String, in apps: [String: AppProfile]) -> String {
        AppCatalog.displayName(forBundleID: bundleID) ?? apps[bundleID]?.name ?? bundleID
    }

    /// Said the same way everywhere it is said: a profile for an app that isn't on this Mac is a
    /// normal thing to have — iCloud sync brings one over from every other Mac — so it reads as a
    /// note about the machine rather than as something wrong with the profile.
    static let notInstalledNote = "not installed on this computer"

    /// The tooltip for a profile's name or icon: the bundle ID, which is the one thing the name
    /// does not say, plus why it is drawn dimmed when it is.
    static func tooltip(_ bundleID: String) -> String {
        AppCatalog.isInstalled(bundleID) ? bundleID : "\(bundleID) — \(notInstalledNote)"
    }
}

/// A profile's icon in a `size × size` box. An app that isn't on this Mac gets a dashed outline:
/// LaunchServices answers an unknown bundle ID with the generic application icon, which is a
/// blank sheet of paper and reads as a broken icon rather than as an app that isn't here.
struct AppIcon: View {
    let bundleID: String
    let size: CGFloat

    var body: some View {
        if AppCatalog.isInstalled(bundleID) {
            Image(nsImage: AppCatalog.icon(forBundleID: bundleID))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "questionmark.app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                // Inset to the size a real icon's artwork draws at inside the same box: an app
                // icon carries the transparent bleed of the macOS icon grid and a symbol does
                // not, so equal frames would leave the placeholder the larger of the two.
                .padding(size * 0.08)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Sidebar

struct AppSidebarRow: View {
    @Environment(AppModel.self) private var model

    let bundleID: String

    var body: some View {
        let installed = AppCatalog.isInstalled(bundleID)
        Label {
            Text(AppProfiles.name(bundleID, in: model.config.apps))
                .lineLimit(1)
                .opacity(installed ? 1 : 0.6)
        } icon: {
            AppIcon(bundleID: bundleID, size: 16)
        }
        .help(AppProfiles.tooltip(bundleID))
    }
}

/// The running apps that have no profile yet, plus a file picker for the ones that aren't running.
struct AddAppMenu: View {
    @Environment(AppModel.self) private var model

    @Binding var selection: SidebarItem?

    var body: some View {
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
            Label("Add App…", systemImage: "plus")
        }
        .fixedSize()
    }

    private func add(bundleID: String, name: String) {
        if model.config.apps[bundleID] == nil {
            model.config.apps[bundleID] = AppProfile(name: name)
        }
        selection = .app(bundleID: bundleID)
    }
}

// MARK: - Detail

/// What the Apps row itself shows: the section has no settings of its own, only the apps under it.
struct AppsOverview: View {
    private static let description = """
    An app profile changes how scrolling feels in that app; every setting you leave alone keeps \
    following the global settings. Button and drag gestures always use the global settings.
    """

    @Environment(AppModel.self) private var model

    @Binding var selection: SidebarItem?

    var body: some View {
        // A scroll view with nothing to scroll. The title bar draws a separator unless a
        // scrolling region is underneath it to take its backdrop from, and every other screen
        // here is a Form — which is one already.
        ScrollView {
            ContentUnavailableView {
                Label(model.config.apps.isEmpty ? "No Apps" : "No App Selected", systemImage: "square.grid.2x2")
            } description: {
                Text(Self.description)
            } actions: {
                AddAppMenu(selection: $selection)
            }
            // Both axes. The height keeps the empty state centred rather than riding the top;
            // the width is what makes the scrolling region the whole column, and the title bar
            // lights the width of its scrolling region — a region as narrow as this view's own
            // content lights a band in the middle of the bar and leaves the rest of it flat.
            .containerRelativeFrame([.horizontal, .vertical])
        }
    }
}
