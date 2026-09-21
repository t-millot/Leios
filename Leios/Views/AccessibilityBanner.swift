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
                // No `.fixedSize(horizontal: false, vertical: true)` here, however much this reads
                // like the place for it. That modifier asks for the ideal height, which SwiftUI
                // measures at the ideal *width* — for a Text, the whole string on one line. This
                // banner sits at the top of the detail column, so that width became the column's
                // ideal, then the split view's, then the window's minimum content width. The
                // window cannot be that wide, so the whole layout was resolved at a size it never
                // got: the sidebar drew nothing at all and the detail pane was clipped to a strip
                // of whichever form was showing. It only happened while the helper was missing
                // Accessibility permission, because that is the one state that puts this view on
                // screen — the app looked broken on exactly the machines seeing it for the first
                // time. The text wraps by itself without the modifier; that is all it was for.
                Text("Leios Helper needs Accessibility access to read and modify mouse input. Enable “LeiosHelper” in System Settings → Privacy & Security → Accessibility.")
                    .font(.callout)
                Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
