// AccessibilityMonitor.swift
// MousePilot Helper — polls AXIsProcessTrusted until granted (ports Helper/AccessibilityCheck.m:262-272).

import AppKit
import ApplicationServices

@MainActor
final class AccessibilityMonitor {

    private(set) var isTrusted = false
    var onTrusted: (() -> Void)?
    var onRevoked: (() -> Void)?
    private var timer: Timer?

    static func check(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func startMonitoring() {
        // The first call registers the helper in System Settings → Accessibility.
        isTrusted = AccessibilityMonitor.check(prompt: false)
        if isTrusted {
            onTrusted?()
        } else {
            NSLog("MousePilot Helper: waiting for Accessibility permission")
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
    }

    private func poll() {
        let trusted = AccessibilityMonitor.check(prompt: false)
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        if trusted { onTrusted?() } else { onRevoked?() }
    }

    /// Prompts the system dialog (only works once per process launch) and opens the settings pane.
    func requestPermission() {
        _ = AccessibilityMonitor.check(prompt: true)
        NSWorkspace.shared.open(MPConstantsBridge.accessibilitySettingsURL)
    }
}

import MousePilotShared
enum MPConstantsBridge {
    static var accessibilitySettingsURL: URL { MPConstants.accessibilitySettingsURL }
}
