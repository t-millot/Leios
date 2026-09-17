// MousePilotApp.swift
// MousePilot — settings app entry point.

import SwiftUI

@main
struct MousePilotApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("MousePilot", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}
