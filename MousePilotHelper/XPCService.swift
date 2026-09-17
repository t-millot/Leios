// XPCService.swift
// MousePilot Helper — NSXPCListener exposing MousePilotHelperXPC to the main app.

import Foundation
import Security
import MousePilotShared
import MousePilotEngine

final class XPCService: NSObject, NSXPCListenerDelegate, MousePilotHelperXPC {

    private let engine: Engine
    private let accessibility: AccessibilityMonitor
    private let configStore: ConfigStore
    private var listener: NSXPCListener?

    init(engine: Engine, accessibility: AccessibilityMonitor, configStore: ConfigStore) {
        self.engine = engine
        self.accessibility = accessibility
        self.configStore = configStore
    }

    func start() {
        let l = NSXPCListener(machServiceName: MPConstants.machServiceName)
        l.delegate = self
        l.resume()
        listener = l
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let team = XPCService.ownTeamIdentifier() {
            connection.setCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        } else {
            #if DEBUG
            NSLog("MousePilot Helper: unsigned build, accepting XPC connection without code-signing requirement")
            #else
            NSLog("MousePilot Helper: no team identifier, rejecting XPC connection")
            return false
            #endif
        }
        connection.exportedInterface = XPC.interface()
        connection.exportedObject = self
        connection.resume()
        return true
    }

    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: MousePilotHelperXPC

    func getStatus(reply: @escaping (String, Bool, Bool) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let running = engine.isRunning
        Task { @MainActor in
            reply(version, self.accessibility.isTrusted, running)
        }
    }

    func reloadConfig(reply: @escaping (Bool) -> Void) {
        Task { @MainActor in
            reply(self.configStore.reload())
        }
    }

    func requestAccessibility() {
        Task { @MainActor in
            self.accessibility.requestPermission()
        }
    }
}
