// XPCProtocol.swift
// MousePilot — the XPC interface exposed by the helper to the main app.

import Foundation

@objc public protocol MousePilotHelperXPC {
    /// Reports the helper's bundle version, whether Accessibility is granted, and whether the engine is running.
    func getStatus(reply: @escaping (_ bundleVersion: String, _ accessibilityTrusted: Bool, _ engineRunning: Bool) -> Void)
    /// Asks the helper to re-read config.json.
    func reloadConfig(reply: @escaping (_ ok: Bool) -> Void)
    /// Asks the helper to open the Accessibility pane (and register itself in the list by prompting).
    func requestAccessibility()
}

public enum XPC {
    public static func interface() -> NSXPCInterface {
        NSXPCInterface(with: MousePilotHelperXPC.self)
    }
}
