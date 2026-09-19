// AppModel.swift
// Leios — observable app state: config document, helper installation and live status.

import Foundation
import AppKit
import CloudKit
import Observation
import os
import LeiosShared

enum HelperState: Equatable {
    case disabled
    case requiresApproval
    case notFound
    case enabledNotRunning
    case running(accessibility: Bool)

    var description: String {
        switch self {
        case .disabled: return "Leios is off"
        case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items"
        // One clause rather than two sentences, so it ends the way the others do.
        case .notFound: return "Helper not found inside the app bundle — rebuild the app"
        case .enabledNotRunning: return "Helper is enabled but not responding yet…"
        case .running(let ax): return ax ? "Running" : "Running, but Accessibility permission is missing"
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

    /// False when `config.json` exists but could not be decoded. The config in memory is then
    /// defaults, which must not be written back over the file the user still has — a config
    /// written by a newer Leios is exactly the kind of file this build cannot read.
    private(set) var configIsReadable = true

    /// Machine-local, so it lives in UserDefaults rather than config.json — the helper has no
    /// business knowing whether this Mac syncs.
    var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            UserDefaults.standard.set(syncEnabled, forKey: DefaultsKey.syncEnabled)
            if syncEnabled { startSync() } else { stopSync() }
        }
    }
    private(set) var syncState: SyncState = .off

    var isEnabled: Bool {
        get { helperState != .disabled && helperState != .notFound }
        set { newValue ? enableHelper() : disableHelper() }
    }

    /// Sparkle, and the two update settings the General tab binds to.
    let updates: UpdateController

    private let log = Logger(subsystem: "com.tmillot.Leios", category: "app")
    private let installer = HelperInstaller()
    private let client = HelperClient()
    private var saveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Guards the stale-helper restart in `refresh()`, which polls every 2 s.
    private var didRestartStaleHelper = false

    private var sync: CloudSync?
    /// The payload this Mac last agreed with the server. Also the upload suppressor: after a
    /// remote apply it already equals the projection, so the save that follows uploads nothing.
    private var lastAgreed: SyncedConfig?
    /// When this Mac first diverged from `lastAgreed`. Persisted, because a Mac edited offline and
    /// then quit must still know it has unsent work rather than adopting a stale remote over it.
    private var localDirtySince: Date? {
        didSet { UserDefaults.standard.set(localDirtySince, forKey: DefaultsKey.localDirtySince) }
    }
    private var syncPollTask: Task<Void, Never>?

    private enum DefaultsKey {
        static let syncEnabled = "sync.enabled"
        static let localDirtySince = "sync.localDirtySince"
    }

    init() {
        // Off in tests: the app host would otherwise put the developer's own iCloud config in the
        // loop, and `LeiosTests` runs against the real Application Support directory.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        syncEnabled = !underTest && UserDefaults.standard.bool(forKey: DefaultsKey.syncEnabled)
        updates = UpdateController(startingUpdater: !underTest)
        localDirtySince = UserDefaults.standard.object(forKey: DefaultsKey.localDirtySince) as? Date
        do {
            config = try ConfigFile.load()
        } catch {
            config = LeiosConfig()
            configIsReadable = false
        }
        // Command-line switches for scripted testing.
        let args = CommandLine.arguments
        if args.contains("--enable-helper") { enableHelper() }
        if args.contains("--disable-helper") { disableHelper() }
        updates.onWillRelaunch = { [weak self] in self?.stopHelperForUpdate() }
        restoreHelperAfterUpdate()
        startPolling()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.reloadConfigFromDisk()
                await self?.refresh()
                await self?.syncNow()
            }
        }
        NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        if syncEnabled { startSync() }
    }

    // MARK: Config persistence

    private func scheduleSave() {
        guard configIsReadable else { return }
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
        syncDidChangeLocally()
    }

    /// Picks up changes made by the helper (menu bar kill switches).
    func reloadConfigFromDisk() {
        do {
            let disk = try ConfigFile.load()
            configIsReadable = true
            if disk != config { config = disk }
        } catch {
            // Leave `config` alone: what is in memory is still the last thing we could read.
            configIsReadable = false
        }
    }

    /// Throws away an unreadable file and starts from the config currently in memory. The only
    /// way out of `configIsReadable == false`, and deliberately a thing the user asks for.
    func discardUnreadableConfig() {
        configIsReadable = true
        saveNow()
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([ConfigFile.url])
    }

    // MARK: iCloud sync

    private func startSync() {
        guard let sync = CloudSync() else {
            syncState = .unavailable
            return
        }
        sync.onUploadResult = { [weak self] payload, outcome in
            self?.handleUpload(of: payload, outcome)
        }
        self.sync = sync
        syncState = .syncing
        syncPollTask?.cancel()
        syncPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                // A window left open overnight still converges. Activation covers the rest;
                // there is no push, so nothing arrives while the app is closed.
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func stopSync() {
        syncPollTask?.cancel()
        syncPollTask = nil
        sync?.cancelPendingUpload()
        sync = nil
        lastAgreed = nil
        syncState = .off
    }

    /// One reconciliation pass: fetch what iCloud holds and act on the reconciler's verdict.
    func syncNow() async {
        guard syncEnabled, let sync, configIsReadable else { return }
        guard await sync.isSignedIn() else {
            syncState = .noAccount
            return
        }
        if case .off = syncState { syncState = .syncing }

        let local = SyncedConfig(config)
        switch await sync.fetch() {
        case .noAccount:
            syncState = .noAccount
        case .failed(let message):
            syncState = .error(message)
        case .incompatible(let device):
            syncState = .incompatible(device: device)
        case .noRecord:
            syncState = .syncing
            handleUpload(of: local, await sync.upload(local))
        case .record(let remote, let stamp):
            switch SyncReconciler.decide(local: local,
                                         remote: remote,
                                         lastAgreed: lastAgreed,
                                         localDirtySince: localDirtySince,
                                         remoteModifiedAt: stamp.modifiedAt) {
            case .upToDate:
                lastAgreed = remote
                localDirtySince = nil
                syncState = .synced(stamp.modifiedAt, device: nil)
            case .applyRemote:
                applyRemote(remote, stamp: stamp)
            case .upload, .seed:
                syncState = .syncing
                handleUpload(of: local, await sync.upload(local))
            }
        }
    }

    /// Called after every successful save. Machine-local edits stop at the equality guard, which
    /// is what keeps a kill-switch flip from producing a CloudKit write.
    private func syncDidChangeLocally() {
        guard syncEnabled, let sync, configIsReadable else { return }
        let projection = SyncedConfig(config)
        guard projection != lastAgreed else { return }
        if localDirtySince == nil { localDirtySince = Date() }
        sync.scheduleUpload(projection)
    }

    private func handleUpload(of payload: SyncedConfig, _ outcome: UploadOutcome) {
        switch outcome {
        case .uploaded(let date):
            lastAgreed = payload
            localDirtySince = nil
            syncState = .synced(date, device: nil)
        case .superseded(let remote, let stamp):
            applyRemote(remote, stamp: stamp)
        case .incompatible(let device):
            syncState = .incompatible(device: device)
        case .noAccount:
            syncState = .noAccount
        case .failed(let message):
            syncState = .error(message)
        }
    }

    /// Merges a payload from another Mac. Only the synced fields move; the kill switches and the
    /// menu bar item stay as this Mac left them.
    private func applyRemote(_ remote: SyncedConfig, stamp: SyncStamp) {
        guard configIsReadable else { return }
        // The helper may have flipped a kill switch while this window was in the background, and
        // those are exactly the fields the payload will not restore.
        reloadConfigFromDisk()
        var candidate = config
        remote.apply(to: &candidate)
        // Before the assignment, not after: the save it triggers is debounced, and by the time
        // that runs the projection already equals `lastAgreed`, so nothing is uploaded back.
        lastAgreed = remote
        localDirtySince = nil
        syncState = .synced(stamp.modifiedAt, device: stamp.deviceName)
        guard candidate != config else { return }
        config = candidate
    }

    func openICloudSettings() {
        NSWorkspace.shared.open(LeiosConstants.appleAccountSettingsURL)
    }

    // MARK: Helper lifecycle

    private func enableHelper() {
        do {
            if configIsReadable { try ConfigFile.save(config) }
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

    // MARK: Helper lifecycle across an update

    /// Stops the helper just before Sparkle replaces the app bundle it lives in.
    ///
    /// Unregistering rather than killing: the launch agent is `KeepAlive`, so launchd would
    /// restart the old executable straight away. The flag is what lets the next launch tell an
    /// update apart from the user switching Leios off — `isEnabled` is derived from `helperState`
    /// and nothing else persists the intent, so without it the new version comes back looking
    /// disabled.
    private func stopHelperForUpdate() {
        UpdateController.helperWasEnabled = (helperState != .disabled && helperState != .notFound)
        try? installer.unregister()
        client.invalidate()
    }

    /// Brings the helper back after an update installed, undoing `stopHelperForUpdate()`.
    private func restoreHelperAfterUpdate() {
        guard UpdateController.helperWasEnabled else { return }
        UpdateController.helperWasEnabled = false
        do {
            try installer.register()
        } catch {
            lastError = "Could not restart the helper after updating: \(error.localizedDescription)"
        }
    }

    /// The app's own build number, which the helper's should match — both targets carry the same
    /// `CURRENT_PROJECT_VERSION`, so they only differ when one of them is left over from an
    /// older bundle.
    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
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
                restartHelperIfStale(reportedVersion: status.bundleVersion)
            } else {
                helperState = .enabledNotRunning
            }
        }
    }

    /// Catches a helper left over from a bundle that has since been replaced — by an update whose
    /// hand-off did not run, or by a user dragging a new copy over the old one. Registering again
    /// makes launchd load the new executable.
    private func restartHelperIfStale(reportedVersion: String) {
        guard HelperRestartDecision.needsRestart(appVersion: bundleVersion,
                                                 helperVersion: reportedVersion,
                                                 alreadyRestarted: didRestartStaleHelper) else { return }
        didRestartStaleHelper = true
        log.notice("Helper reports build \(reportedVersion, privacy: .public), app is \(self.bundleVersion, privacy: .public) — restarting it")
        try? installer.register()
        client.invalidate()
    }
}
