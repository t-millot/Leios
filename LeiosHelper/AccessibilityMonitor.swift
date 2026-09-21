// AccessibilityMonitor.swift
// Leios Helper — polls AXIsProcessTrusted until granted (ports Helper/AccessibilityCheck.m:262-272).

import AppKit
import ApplicationServices

@MainActor
final class AccessibilityMonitor {

    private(set) var isTrusted = false
    var onTrusted: (() -> Void)?
    var onRevoked: (() -> Void)?
    private var timer: Timer?

    /// Never prompts, deliberately. The prompting form puts the system's "would like to control
    /// this Mac" dialog on screen, which fires at most once per process launch and offers nothing
    /// the banner's button does not do better — and it is the call, not the dialog, that lists the
    /// helper in System Settings. Asking without the prompt is what leaves the app in charge of
    /// when the pane opens.
    static func check() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func startMonitoring() {
        // The first call is what registers the helper in System Settings → Privacy & Security →
        // Device Control and Data Access, so its row is there before the user goes looking.
        isTrusted = AccessibilityMonitor.check()
        if isTrusted {
            onTrusted?()
        } else {
            NSLog("Leios Helper: waiting for Accessibility permission")
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
    }

    private func poll() {
        let trusted = AccessibilityMonitor.check()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        if trusted { onTrusted?() } else { onRevoked?() }
    }
}
