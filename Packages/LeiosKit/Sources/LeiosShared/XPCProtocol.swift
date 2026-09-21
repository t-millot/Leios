// XPCProtocol.swift
// Leios — the XPC interface exposed by the helper to the main app.

import Foundation

@objc public protocol LeiosHelperXPC {
    /// Reports the helper's bundle version, whether Accessibility is granted, and whether the engine is running.
    func getStatus(reply: @escaping (_ bundleVersion: String, _ accessibilityTrusted: Bool, _ engineRunning: Bool) -> Void)
    /// Asks the helper to re-read config.json.
    func reloadConfig(reply: @escaping (_ ok: Bool) -> Void)
    /// Swallows the next mouse-button press so the app can add that button, even when the button
    /// already has an assignment and would otherwise be consumed by the engine.
    /// Replies exactly once, with the button number (3…32), `ButtonCapture.timedOut` or `.unavailable`.
    func captureNextButton(timeout: Double, reply: @escaping (_ button: Int) -> Void)
    /// Ends an armed capture early; its pending reply arrives as `ButtonCapture.timedOut`.
    func cancelButtonCapture()
    /// Writes the usage statistics counted so far to disk, so the settings app reads current
    /// figures rather than ones up to a flush interval old. Replies once the file is written.
    func flushStatistics(reply: @escaping (_ ok: Bool) -> Void)
    /// Discards the recorded usage statistics, including anything counted but not yet written.
    func resetStatistics(reply: @escaping (_ ok: Bool) -> Void)
}

/// Reply values of `captureNextButton`.
public enum ButtonCapture {
    /// No button was pressed before the timeout, or the capture was cancelled.
    public static let timedOut = 0
    /// The engine is not running (disabled, or no Accessibility permission), so nothing can be captured.
    public static let unavailable = -1
    /// Longest capture the helper will arm, so a forgotten capture cannot swallow clicks forever.
    public static let maxTimeout: Double = 300
}

public enum XPC {
    public static func interface() -> NSXPCInterface {
        NSXPCInterface(with: LeiosHelperXPC.self)
    }
}
