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
