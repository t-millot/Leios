// XPCService.swift
// Leios Helper — NSXPCListener exposing LeiosHelperXPC to the main app.

import Foundation
import Security
import LeiosShared
import LeiosEngine

final class XPCService: NSObject, NSXPCListenerDelegate, LeiosHelperXPC {

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
        let l = NSXPCListener(machServiceName: LeiosConstants.machServiceName)
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
            NSLog("Leios Helper: unsigned build, accepting XPC connection without code-signing requirement")
            #else
            NSLog("Leios Helper: no team identifier, rejecting XPC connection")
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

    // MARK: LeiosHelperXPC

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

    func captureNextButton(timeout: Double, reply: @escaping (Int) -> Void) {
        let bounded = min(max(timeout, 1), ButtonCapture.maxTimeout)
        // The reply block crosses to the engine thread, and calling it twice would tear the
        // connection down, so it is handed over as a one-shot.
        let once = OneShotReply(reply)
        engine.captureNextButton(timeout: bounded) { once.call($0) }
    }

    func cancelButtonCapture() {
        engine.cancelButtonCapture()
    }

    func flushStatistics(reply: @escaping (Bool) -> Void) {
        // Same one-shot treatment as the capture reply: this one comes back from the statistics
        // queue, and a reply block called twice tears the connection down.
        let once = OneShotReply(reply)
        engine.flushStatistics { once.call(true) }
    }

    func resetStatistics(reply: @escaping (Bool) -> Void) {
        let once = OneShotReply(reply)
        engine.resetStatistics { once.call(true) }
    }
}

/// Calls an XPC reply block at most once, from any thread.
private final class OneShotReply<Value>: @unchecked Sendable {
    private var reply: ((Value) -> Void)?
    private let lock = NSLock()
    init(_ reply: @escaping (Value) -> Void) { self.reply = reply }
    func call(_ value: Value) {
        lock.lock()
        let reply = self.reply
        self.reply = nil
        lock.unlock()
        reply?(value)
    }
}
