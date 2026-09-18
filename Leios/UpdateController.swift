// UpdateController.swift
// Leios — Sparkle's updater, and the two settings that steer it.

import Foundation
import Observation
import Sparkle

/// Owns the Sparkle updater and exposes the parts the settings UI binds to.
///
/// Both settings are machine-local, so they live in `UserDefaults` rather than in `config.json`
/// — the same reasoning as `AppModel.syncEnabled`. Nothing here reaches `LeiosConfig`, so nothing
/// reaches `SyncedConfig` or the helper: whether this Mac takes betas is not a thing to sync.
///
/// The helper is the one complication. It runs out of `Contents/Library/LoginItems` *inside the
/// bundle Sparkle replaces*, so it has to be stopped before the swap; `onWillRelaunch` is that
/// hand-off, and `AppModel` supplies it. The dependency only points one way — this type never
/// reaches back into `AppModel`.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {

    /// Sparkle's name for the prerelease channel. Items without a channel go to everyone, so
    /// only prerelease appcast items carry this one; `Scripts/release.sh` writes it.
    private static let betaChannel = "beta"

    private enum DefaultsKey {
        static let automaticallyChecks = "updates.automaticallyChecks"
        static let includePrereleases = "updates.includePrereleases"
        /// Set only for the moment between unregistering the helper for an install and
        /// registering it again on the next launch. See `AppModel.restoreHelperAfterUpdate()`.
        static let helperWasEnabled = "updates.helperWasEnabled"
        /// A feed to use instead of the one in Info.plist, for testing an update end to end
        /// without cutting a release. Also readable from the `LEIOS_APPCAST_URL` environment
        /// variable, in the spirit of the `--enable-helper` launch argument.
        static let appcastURL = "updates.appcastURL"
    }

    /// Called immediately before Sparkle terminates the app to install. Stops the helper, so the
    /// bundle is not in use when it is replaced.
    var onWillRelaunch: (() -> Void)?

    private var controller: SPUStandardUpdaterController!

    /// False under XCTest, where `LeiosTests` is hosted by the app: a started updater would put a
    /// real scheduled check — and eventually a real update window — into a test run.
    private let isStarted: Bool

    private var updater: SPUUpdater { controller.updater }

    var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
            UserDefaults.standard.set(automaticallyChecks, forKey: DefaultsKey.automaticallyChecks)
        }
    }

    var includePrereleases: Bool {
        didSet {
            guard includePrereleases != oldValue else { return }
            UserDefaults.standard.set(includePrereleases, forKey: DefaultsKey.includePrereleases)
            // Without this a user who just opted in waits out the rest of the check interval
            // before the beta they asked for appears.
            updater.resetUpdateCycle()
        }
    }

    /// False while a check is already running, which is what disables the "Check Now" button.
    var canCheckForUpdates: Bool { isStarted && updater.canCheckForUpdates }

    var lastCheckDate: Date? { updater.lastUpdateCheckDate }

    init(startingUpdater: Bool) {
        isStarted = startingUpdater
        let defaults = UserDefaults.standard
        // Deciding here rather than leaving it unset suppresses Sparkle's own first-run
        // "check automatically?" prompt. A new user already meets the Accessibility and Login
        // Items prompts; a third one asking about updates is one too many.
        let hasDecided = defaults.object(forKey: DefaultsKey.automaticallyChecks) != nil
        automaticallyChecks = hasDecided ? defaults.bool(forKey: DefaultsKey.automaticallyChecks) : true
        includePrereleases = defaults.bool(forKey: DefaultsKey.includePrereleases)
        super.init()

        controller = SPUStandardUpdaterController(startingUpdater: startingUpdater, updaterDelegate: self, userDriverDelegate: nil)
        updater.automaticallyChecksForUpdates = automaticallyChecks
        // Notify, never install silently: an install that goes through terminate-and-relaunch is
        // the only one where `updaterWillRelaunchApplication` reliably fires, and that callback is
        // where the helper gets stopped.
        updater.automaticallyDownloadsUpdates = false
        if !hasDecided { defaults.set(automaticallyChecks, forKey: DefaultsKey.automaticallyChecks) }
    }

    func checkForUpdates() {
        guard isStarted else { return }
        updater.checkForUpdates()
    }

    // MARK: Helper hand-off across an install

    /// Records that the helper was running, so the next launch can bring it back. Read and
    /// cleared by `AppModel`.
    static var helperWasEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.helperWasEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.helperWasEnabled) }
    }

    // MARK: SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // Stable items carry no channel and reach everyone; this is the whole prerelease opt-in.
        includePrereleases ? [Self.betaChannel] : []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // nil falls through to SUFeedURL in Info.plist, which is the normal path.
        ProcessInfo.processInfo.environment["LEIOS_APPCAST_URL"]
            ?? UserDefaults.standard.string(forKey: DefaultsKey.appcastURL)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // The last callback before the app terminates and the installer replaces the bundle.
        onWillRelaunch?()
    }
}
