// ScrollFieldSource.swift
// Leios — where one scroll settings screen reads and writes its values.

import SwiftUI
import LeiosShared

/// Backs a `ScrollSettingsForm`: either the global settings, or one app's profile, where a field
/// the user never touched keeps following the global value.
///
/// Each field is addressed by a pair of key paths — one into `ScrollSettings` for the global value,
/// one into `ScrollOverrides` for the app's pinned value — so the form is written once.
struct ScrollFieldSource {
    let model: AppModel
    /// nil for the global Scrolling tab.
    let bundleID: String?

    var isProfile: Bool { bundleID != nil }

    /// The values actually in force on this screen.
    var effective: ScrollSettings {
        guard let bundleID, let profile = model.config.apps[bundleID] else { return model.config.scroll }
        return profile.scroll.resolved(against: model.config.scroll)
    }

    func binding<V: Equatable>(_ global: WritableKeyPath<ScrollSettings, V>,
                               _ override: WritableKeyPath<ScrollOverrides, V?>) -> Binding<V> {
        Binding(
            get: {
                if let bundleID, let pinned = model.config.apps[bundleID]?.scroll[keyPath: override] { return pinned }
                return model.config.scroll[keyPath: global]
            },
            set: { newValue in
                if let bundleID {
                    model.config.apps[bundleID, default: AppProfile()].scroll[keyPath: override] = newValue
                } else {
                    model.config.scroll[keyPath: global] = newValue
                }
            })
    }

    /// True when this app has pinned the field, so it no longer follows the global setting.
    func isOverridden<V>(_ override: KeyPath<ScrollOverrides, V?>) -> Bool {
        guard let bundleID else { return false }
        return model.config.apps[bundleID]?.scroll[keyPath: override] != nil
    }

    /// Unpins the field, so it follows the global setting again.
    func clear<V>(_ override: WritableKeyPath<ScrollOverrides, V?>) {
        guard let bundleID else { return }
        model.config.apps[bundleID]?.scroll[keyPath: override] = nil
    }
}
