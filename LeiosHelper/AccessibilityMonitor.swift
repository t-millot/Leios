// AccessibilityMonitor.swift
// Leios Helper — polls AXIsProcessTrusted until granted (ports Helper/AccessibilityCheck.m:262-272).

import AppKit
import ApplicationServices

@MainActor
final class AccessibilityMonitor: NSObject {

    private(set) var isTrusted = false
    var onTrusted: (() -> Void)?
    var onRevoked: (() -> Void)?
    private var timer: Timer?

    /// While waiting, the user is in System Settings right now and the engine should start the
    /// moment the switch flips, so the check runs often.
    private static let untrustedInterval: TimeInterval = 0.5
    /// Once granted, the poll only exists to notice a revocation. Each check is a round trip to
    /// tccd — about 170 µs, and a wakeup for both processes — which at the waiting rate is two
    /// wakeups a second for the life of the login session. The system's accessibility
    /// notification (below) usually reports a change long before this interval would.
    private static let trustedInterval: TimeInterval = 3
    /// Posted by the system whenever the Accessibility list changes, for any app. TCC has not
    /// always committed the change when it arrives, hence the short delay before checking.
    private static let accessibilityChanged = Notification.Name("com.apple.accessibility.api")
    private nonisolated static let notificationSettleDelay: TimeInterval = 0.3

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
        // `.deliverImmediately`: a background agent is never the active app, and distributed
        // notifications are otherwise held back until it is.
        DistributedNotificationCenter.default().addObserver(self,
                                                            selector: #selector(accessibilityListChanged),
                                                            name: Self.accessibilityChanged,
                                                            object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        schedulePolling()
    }

    private func schedulePolling() {
        timer?.invalidate()
        let interval = isTrusted ? Self.trustedInterval : Self.untrustedInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
        timer.tolerance = interval / 10
        self.timer = timer
    }

    @objc private nonisolated func accessibilityListChanged(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notificationSettleDelay) { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let trusted = AccessibilityMonitor.check()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        schedulePolling()
        if trusted { onTrusted?() } else { onRevoked?() }
    }
}
