// RootView.swift
// Leios — main window.

import SwiftUI
import LeiosShared

/// One row of the sidebar. App profiles are rows too — the Apps row expands into them, so a
/// profile is one click away rather than a list nested inside a screen.
enum SidebarItem: Hashable {
    case scrolling
    case apps
    case app(bundleID: String)
    case buttons
    case devices
    case statistics
    case settings

    var title: String {
        switch self {
        case .scrolling: "Scrolling"
        case .apps: "Apps"
        case .app(let bundleID): bundleID
        case .buttons: "Buttons"
        case .devices: "Devices"
        case .statistics: "Statistics"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .scrolling: "arrow.up.and.down"
        case .apps: "square.grid.2x2"
        case .app: "app"
        case .buttons: "computermouse"
        case .devices: "cable.connector.horizontal"
        case .statistics: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var enableLabel

    @State private var selection: SidebarItem? = .scrolling
    @State private var appsExpanded = true
    @State private var pendingRemoval: String?

    var body: some View {
        @Bindable var model = model
        return NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        // Right-clicking a toolbar item offers to switch it between "Icon and Text" and "Icon
        // Only". The one item here is an icon and nothing else, so the choice is meaningless —
        // and NSToolbar answers that click above the hosted view, where SwiftUI cannot.
        .background(WindowConfigurator { $0.toolbar?.allowsDisplayModeCustomization = false })
        .confirmationDialog("Remove \(AppProfiles.name(pendingRemoval ?? "", in: model.config.apps))?",
                            isPresented: removalPrompt,
                            presenting: pendingRemoval) { bundleID in
            Button("Remove", role: .destructive) { confirmRemoval(bundleID) }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { bundleID in
            Text("\(AppProfiles.name(bundleID, in: model.config.apps)) will go back to the global scroll settings.")
        }
        .onAppear { AppCatalog.refresh() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            // Above the navigation rather than in the toolbar: the switch turns the whole app on
            // and off, so it belongs to no one screen, and here it has room for the state it used
            // to keep in a tooltip.
            enableHeader
            List(selection: $selection) {
                row(.scrolling)
                appsGroup
                row(.buttons)
                row(.devices)
                row(.statistics)
                row(.settings)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        // The sidebar is the whole navigation — there is nowhere to get back to once it is hidden.
        .toolbar(removing: .sidebarToggle)
        .onDeleteCommand(perform: deleteSelectedApp)
    }

    private var enableHeader: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 0) {
                Text("Enable Leios")
                    .fontWeight(.medium)
                    .accessibilityLabeledPair(role: .label, id: "enable", in: enableLabel)
                Text(model.helperState.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Toggle("Enable Leios", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabeledPair(role: .content, id: "enable", in: enableLabel)
        }
        .help(model.helperState.description)
        // The List insets its own rows; this sits outside it and matches that inset by hand.
        .padding(.horizontal, 14)
        // Clear of the window controls, which the sidebar's safe area only just clears.
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol).tag(item)
    }

    private var appsGroup: some View {
        DisclosureGroup(isExpanded: $appsExpanded) {
            ForEach(AppProfiles.sorted(model.config.apps), id: \.self) { bundleID in
                AppSidebarRow(bundleID: bundleID)
                    .tag(SidebarItem.app(bundleID: bundleID))
                    .contextMenu {
                        Button("Remove", role: .destructive) { remove(bundleID) }
                    }
            }
        } label: {
            row(.apps)
                .contextMenu { AddAppMenu(selection: $selection).labelsHidden() }
        }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            if hasStatusContent {
                statusBanner
                Divider()
            }
            switch resolvedSelection {
            case .scrolling: ScrollingSettingsView()
            case .apps: AppsOverview(selection: $selection)
            case .app(let bundleID): ScrollSettingsForm(source: ScrollFieldSource(model: model, bundleID: bundleID))
            case .buttons: ButtonsSettingsView()
            case .devices: DevicesSettingsView()
            case .statistics: StatisticsView(selection: $selection)
            case .settings: GeneralSettingsView()
            }
        }
        .navigationTitle(detailTitle)
        .navigationSubtitle(detailSubtitle)
    }

    /// The window title is the section title: the title bar sits over the detail column, so it
    /// names what is under it rather than repeating the app's own name on every screen.
    private var detailTitle: String {
        if case .app(let bundleID) = resolvedSelection {
            return AppProfiles.name(bundleID, in: model.config.apps)
        }
        return resolvedSelection.title
    }

    /// Only an app profile has one: the bundle ID, which is the one thing its name does not say.
    private var detailSubtitle: String {
        if case .app(let bundleID) = resolvedSelection { return bundleID }
        return ""
    }

    /// An app profile names itself here rather than in a strip below: two rows of chrome, one of
    /// them a title bar and the other pretending to be, read as a mistake.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if case .app(let bundleID) = resolvedSelection {
            // Only the icon is ours. The name and the bundle ID are the window's own title and
            // subtitle, so they come out in the same type as every other screen's title instead
            // of in a hand-sized copy of it.
            ToolbarItem(placement: .navigation) {
                Image(nsImage: AppCatalog.icon(forBundleID: bundleID))
                    .resizable()
                    // 29 to draw 25: an app icon carries the transparent bleed of the macOS icon
                    // grid, and it is the artwork that has to stand as tall as the two lines of
                    // text beside it.
                    .frame(width: 29, height: 29)
                    .opacity(AppCatalog.isInstalled(bundleID) ? 1 : 0.6)
                    .help(AppCatalog.isInstalled(bundleID) ? bundleID : "\(bundleID) — not installed")
                    .accessibilityHidden(true)
                    // Toolbar items are spaced from each other as controls, which left 18pt
                    // between the icon and the title it belongs to. This closes it to 11.
                    .padding(.trailing, -14)
            }
            // A toolbar item is a control, and the toolbar draws controls in shared glass.
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { remove(bundleID) } label: {
                    // The role alone leaves the glyph the same grey as any other toolbar button.
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .accessibilityLabel("Remove")
                .buttonBorderShape(.circle)
                .tint(.red)
                .help("Remove this app's settings")
            }
        } else {
            // A toolbar with nothing in it collapses the title bar to a compact height, and the
            // window would change shape as the selection moved. This holds it open, and sits at
            // the trailing edge because a leading item indents the title away from where an app
            // profile puts its own.
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: 0, height: 24)
            }
        }
    }

    /// A profile can go away under the selection — removed here, or arriving over iCloud — and a
    /// row that no longer exists would otherwise leave the detail pane showing a stale app.
    private var resolvedSelection: SidebarItem {
        guard let selection else { return .scrolling }
        if case .app(let bundleID) = selection, model.config.apps[bundleID] == nil { return .apps }
        return selection
    }

    /// Delete only ever means a profile: the fixed rows are the app's navigation.
    private func deleteSelectedApp() {
        guard case .app(let bundleID) = selection else { return }
        remove(bundleID)
    }

    /// Every way in — the trash button, the row's context menu, the Delete key — asks first.
    /// A profile is a set of choices the user made by feel, and nothing here undoes.
    private func remove(_ bundleID: String) {
        pendingRemoval = bundleID
    }

    private var removalPrompt: Binding<Bool> {
        Binding(get: { pendingRemoval != nil },
                set: { showing in if !showing { pendingRemoval = nil } })
    }

    private func confirmRemoval(_ bundleID: String) {
        model.config.apps[bundleID] = nil
        if selection == .app(bundleID: bundleID) { selection = .apps }
        pendingRemoval = nil
    }

    // MARK: Status

    /// The header only exists for things that need the user's attention; when the helper is
    /// simply running, its state lives in the toolbar dot's tooltip and the window stays clean.
    private var hasStatusContent: Bool {
        if !model.configIsReadable { return true }
        if model.lastError != nil { return true }
        if model.helperState == .requiresApproval { return true }
        if model.helperIsUnreachable { return true }
        if case .running(let ax) = model.helperState, !ax { return true }
        return false
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.configIsReadable {
                Text("Leios could not read its settings file, so it is showing defaults. Nothing has been written over it.")
                    .font(.callout)
                    .foregroundStyle(.red)
                HStack {
                    Button("Reveal in Finder") { model.revealConfigInFinder() }
                    Button("Discard and Start Fresh") { model.discardUnreadableConfig() }
                }
            }
            if let error = model.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if model.helperState == .requiresApproval {
                Text(model.helperState.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
            }
            // Named rather than left to the sidebar caption, which reads as "still starting" and so
            // says nothing at all once the helper is never going to answer.
            if model.helperIsUnreachable {
                Text("Leios is on, but its background helper is not responding, so nothing is being remapped. This usually follows installing a different version over the app.")
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("Restart the Helper") { model.reregisterHelper() }
            }
            if case .running(let ax) = model.helperState, !ax {
                AccessibilityBanner()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var statusDot: some View {
        let color: Color
        switch model.helperState {
        case .running(let ax): color = ax ? .green : .orange
        case .disabled, .notFound: color = .gray
        case .requiresApproval, .enabledNotRunning: color = .orange
        }
        // An Image rather than a Circle: a bare shape is decorative, so VoiceOver drops the label.
        return Image(systemName: "circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(color)
            .accessibilityLabel("Status")
            .accessibilityValue(model.helperState.description)
    }
}

/// Reaches the `NSWindow` behind the view, for the window-level settings SwiftUI does not surface.
private struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        // The view has no window until it is in the hierarchy, which is after this returns.
        DispatchQueue.main.async { view.window.map(configure) }
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        view.window.map(configure)
    }
}
