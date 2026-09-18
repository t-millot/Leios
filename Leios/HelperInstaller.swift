// HelperInstaller.swift
// Leios — registers/unregisters the helper launch agent via SMAppService.

import Foundation
import ServiceManagement
import LeiosShared

struct HelperInstaller {

    enum State: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    private var service: SMAppService { SMAppService.agent(plistName: LeiosConstants.launchdPlistName) }

    var state: State {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws {
        // Re-registering refreshes a stale registration (e.g. after the app moved).
        if service.status == .enabled { try? service.unregister() }
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Whether the helper answering XPC right now is stale and has to be restarted.
///
/// The helper lives *inside* the app bundle, so replacing that bundle — by a Sparkle install, or
/// by a user dragging a new copy over the old one — leaves launchd running the old executable
/// from the replaced inode. Nothing announces it: the app is new, the engine is not. Registering
/// again is what makes launchd pick the new binary up.
///
/// A pure function so the rule can be tested without a real registration, like `SyncReconciler`.
enum HelperRestartDecision {

    static func needsRestart(appVersion: String, helperVersion: String, alreadyRestarted: Bool) -> Bool {
        // Once per launch: a registration that does not take must not turn into a restart loop.
        guard !alreadyRestarted else { return false }
        // An unknown version on either side is not evidence of staleness, and restarting the
        // engine under someone's hand is worse than leaving a stale one running.
        guard !appVersion.isEmpty, !helperVersion.isEmpty else { return false }
        return appVersion != helperVersion
    }
}
