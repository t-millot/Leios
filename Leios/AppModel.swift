// AppModel.swift
// Leios — observable app state: config document, helper installation and live status.

import Foundation
import AppKit
import Observation
import LeiosShared

enum HelperState: Equatable {
    case disabled
    case requiresApproval
    case notFound
    case enabledNotRunning
    case running(accessibility: Bool)

    var description: String {
        switch self {
        case .disabled: return "Leios is off."
        case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items."
        case .notFound: return "Helper not found inside the app bundle. Rebuild the app."
        case .enabledNotRunning: return "Helper is enabled but not responding yet…"
        case .running(let ax): return ax ? "Running." : "Running, but Accessibility permission is missing."
        }
    }
}

@MainActor
@Observable
final class AppModel {

    var config: LeiosConfig {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
        }
    }
    private(set) var helperState: HelperState = .disabled
    private(set) var lastError: String?

    var isEnabled: Bool {
        get { helperState != .disabled && helperState != .notFound }
        set { newValue ? enableHelper() : disableHelper() }
    }

    private let installer = HelperInstaller()
    private let client = HelperClient()
    private var saveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init() {
        config = (try? ConfigFile.load()) ?? LeiosConfig()
        // Command-line switches for scripted testing.
        let args = CommandLine.arguments
        if args.contains("--enable-helper") { enableHelper() }
        if args.contains("--disable-helper") { disableHelper() }
        startPolling()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.reloadConfigFromDisk()
                await self?.refresh()
            }
        }
    }

    // MARK: Config persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        do {
            try ConfigFile.save(config)
            lastError = nil
        } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
        }
        Task { await client.reloadConfig() }
    }

    /// Picks up changes made by the helper (menu bar kill switches).
    func reloadConfigFromDisk() {
        if let disk = try? ConfigFile.load(), disk != config {
            config = disk
        }
    }

    // MARK: Helper lifecycle

    private func enableHelper() {
        do {
            try ConfigFile.save(config)
            try installer.register()
            lastError = nil
        } catch {
            lastError = "Could not enable the helper: \(error.localizedDescription)"
        }
        Task { await refresh() }
    }

    private func disableHelper() {
        do {
            try installer.unregister()
            lastError = nil
        } catch {
            lastError = "Could not disable the helper: \(error.localizedDescription)"
        }
        client.invalidate()
        Task { await refresh() }
    }

    func openLoginItemsSettings() {
        HelperInstaller.openLoginItemsSettings()
    }

    // MARK: Button capture

    /// Asks the helper to swallow the next mouse-button press and report it, so buttons that already
    /// have an assignment can be added too — their press never reaches the app on its own.
    func captureButtonFromHelper(timeout: TimeInterval = 60) async -> ButtonCaptureOutcome {
        guard case .running(let accessibility) = helperState, accessibility else { return .unavailable }
        return await client.captureNextButton(timeout: timeout)
    }

    func cancelButtonCapture() {
        client.cancelButtonCapture()
    }

    func openAccessibilitySettings() {
        client.requestAccessibility()
        NSWorkspace.shared.open(LeiosConstants.accessibilitySettingsURL)
    }

    // MARK: Status polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        switch installer.state {
        case .notRegistered:
            helperState = .disabled
        case .requiresApproval:
            helperState = .requiresApproval
        case .notFound:
            helperState = .notFound
        case .enabled:
            if let status = await client.getStatus() {
                helperState = .running(accessibility: status.accessibilityTrusted)
            } else {
                helperState = .enabledNotRunning
            }
        }
    }
}
