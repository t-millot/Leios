// ScrollingSettingsView.swift
// MousePilot — global scroll wheel settings. Apps with their own profile override these
// per field; see AppsSettingsView.

import SwiftUI

struct ScrollingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollSettingsForm(source: ScrollFieldSource(model: model, bundleID: nil))
    }
}
