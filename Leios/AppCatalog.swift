// AppCatalog.swift
// Leios — resolving bundle identifiers to names and icons for the Apps tab.

import AppKit
import UniformTypeIdentifiers

/// Looks up installed and running applications. Results are memoised: the Apps list asks for a
/// name and an icon on every body pass, and LaunchServices lookups are far too slow for that.
enum AppCatalog {

    private static var urls: [String: URL?] = [:]
    private static var names: [String: String?] = [:]
    private static var icons: [String: NSImage] = [:]

    /// Drops the memo so newly installed apps are picked up. Called when the Apps tab appears.
    static func refresh() {
        urls.removeAll()
        names.removeAll()
        icons.removeAll()
    }

    static func url(forBundleID bundleID: String) -> URL? {
        if let cached = urls[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        urls[bundleID] = url
        return url
    }

    static func isInstalled(_ bundleID: String) -> Bool { url(forBundleID: bundleID) != nil }

    /// The app's own name, or nil when it can't be found on disk any more.
    ///
    /// Memoised like the rest: the localised name is a LaunchServices round trip of about 120 µs,
    /// and sorting the sidebar asks for two names per comparison on every pass — which, since the
    /// sidebar reads the config, is every frame of a slider being dragged anywhere in the window.
    static func displayName(forBundleID bundleID: String) -> String? {
        if let cached = names[bundleID] { return cached }
        let name = url(forBundleID: bundleID).map { FileManager.default.displayName(atPath: $0.path) }
        names[bundleID] = name
        return name
    }

    /// The app's icon. An app that isn't on this Mac is drawn by `AppIcon` rather than here — the
    /// generic icon LaunchServices falls back to is a blank sheet of paper — so the fallback is
    /// only a safety net for a bundle that disappears between the two calls.
    static func icon(forBundleID bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let icon: NSImage
        if let url = url(forBundleID: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .application)
        }
        icons[bundleID] = icon
        return icon
    }

    /// Apps with a normal user interface, for the "+" menu. Leios itself is excluded — the
    /// settings window does not scroll anything worth profiling.
    static func runningApps() -> [(bundleID: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [(bundleID: String, name: String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != own, seen.insert(bundleID).inserted else { continue }
            result.append((bundleID, app.localizedName ?? bundleID))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Asks the user to pick an application bundle. Returns nil if they cancel or pick Leios.
    static func chooseApplication() -> (bundleID: String, name: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose an application to give its own scroll settings."
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier
        else { return nil }
        return (bundleID, FileManager.default.displayName(atPath: url.path))
    }
}
