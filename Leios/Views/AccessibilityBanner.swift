// AccessibilityBanner.swift
// Leios — shown while the helper lacks Accessibility permission.

import SwiftUI

struct AccessibilityBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Accessibility permission required").font(.headline)
                Text("Leios Helper needs Accessibility access to read and modify mouse input. Enable “LeiosHelper” in System Settings → Privacy & Security → Accessibility.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
