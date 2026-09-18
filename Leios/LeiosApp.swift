// LeiosApp.swift
// Leios — settings app entry point.

import SwiftUI

@main
struct LeiosApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Leios", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 700, minHeight: 540)
        }
        // .contentMinSize, not .contentSize: the Apps tab's list and detail pane change the ideal
        // size as the selection changes, and .contentSize would resize the window under the user.
        .windowResizability(.contentMinSize)
    }
}
