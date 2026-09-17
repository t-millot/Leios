// RootView.swift
// MousePilot — main window.

import SwiftUI
import MousePilotShared

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            TabView {
                ScrollingSettingsView().tabItem { Label("Scrolling", systemImage: "arrow.up.and.down") }
                ButtonsSettingsView().tabItem { Label("Buttons", systemImage: "computermouse") }
                GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            }
            .padding()
        }
    }

    private var header: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $model.isEnabled) {
                    Text("Enable MousePilot").font(.title3.weight(.semibold))
                }
                .toggleStyle(.switch)
                Spacer()
                statusDot
            }
            Text(model.helperState.description)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = model.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if model.helperState == .requiresApproval {
                Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
            }
            if case .running(let ax) = model.helperState, !ax {
                AccessibilityBanner()
            }
        }
        .padding()
    }

    private var statusDot: some View {
        let color: Color
        switch model.helperState {
        case .running(let ax): color = ax ? .green : .orange
        case .disabled, .notFound: color = .gray
        case .requiresApproval, .enabledNotRunning: color = .orange
        }
        return Circle().fill(color).frame(width: 10, height: 10)
    }
}
