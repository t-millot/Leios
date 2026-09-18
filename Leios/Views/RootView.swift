// RootView.swift
// Leios — main window.

import SwiftUI
import LeiosShared

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var enableLabel

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            if hasStatusContent {
                statusBanner
                Divider()
            }
            TabView {
                ScrollingSettingsView().tabItem { Label("Scrolling", systemImage: "arrow.up.and.down") }
                AppsSettingsView().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                ButtonsSettingsView().tabItem { Label("Buttons", systemImage: "computermouse") }
                InfoSettingsView().tabItem { Label("Info", systemImage: "info.circle") }
                GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            }
            // No top padding: the tab picker sits in the toolbar, so a top inset here reads as a
            // gap between the title bar and the content.
            .padding([.horizontal, .bottom])
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // The label goes in its own Text: a toolbar item strips a Toggle's own label.
                HStack(spacing: 6) {
                    Text("Enable")
                        .accessibilityLabeledPair(role: .label, id: "enable", in: enableLabel)
                    Toggle("Enable", isOn: $model.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        // A regular switch fills the toolbar item's glass pill edge to edge.
                        .controlSize(.mini)
                        .accessibilityLabeledPair(role: .content, id: "enable", in: enableLabel)
                    statusDot
                }
                // Without this the label truncates to "E…".
                .fixedSize()
                .padding(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 10))
            }
        }
    }

    /// The header only exists for things that need the user's attention; when the helper is
    /// simply running, its state lives in the toolbar dot's tooltip and the window stays clean.
    private var hasStatusContent: Bool {
        if model.lastError != nil { return true }
        if model.helperState == .requiresApproval { return true }
        if case .running(let ax) = model.helperState, !ax { return true }
        return false
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if model.helperState == .requiresApproval {
                Text(model.helperState.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
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
        // The padding is there because a 10pt dot is too small to hover for the tooltip.
        return Image(systemName: "circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(color)
            .padding(4)
            .contentShape(Rectangle())
            .accessibilityLabel("Status")
            .accessibilityValue(model.helperState.description)
            .help(model.helperState.description)
    }
}
