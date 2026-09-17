// HelperAppDelegate.swift
// MousePilot Helper — startup ordering: signals → XPC → config → status menu → accessibility → Engine.
// Mirrors the ordering documented in Mac Mouse Fix's Helper/AccessibilityCheck.m.

import AppKit
import MousePilotShared
import MousePilotEngine

@MainActor
final class HelperAppDelegate: NSObject, NSApplicationDelegate {

    private var engine: Engine!
    private var configStore: ConfigStore!
    private var xpcService: XPCService!
    private var accessibility: AccessibilityMonitor!
    private var statusMenu: StatusMenu!
    private var signals: TerminationSignals!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let initialConfig = (try? ConfigFile.load()) ?? MousePilotConfig()
        engine = Engine(config: initialConfig)

        signals = TerminationSignals { [weak self] in
            self?.engine.stop()
        }
        signals.install()

        configStore = ConfigStore(initial: initialConfig)
        configStore.onChange = { [weak self] config in
            guard let self else { return }
            self.engine.apply(config)
            self.statusMenu.update(config: config)
        }
        configStore.startWatching()

        accessibility = AccessibilityMonitor()
        xpcService = XPCService(engine: engine, accessibility: accessibility, configStore: configStore)
        xpcService.start()

        statusMenu = StatusMenu(configStore: configStore)
        statusMenu.update(config: initialConfig)

        accessibility.onTrusted = { [weak self] in
            guard let self else { return }
            NSLog("MousePilot Helper: Accessibility granted, starting engine")
            self.engine.start()
        }
        accessibility.onRevoked = { [weak self] in
            guard let self else { return }
            NSLog("MousePilot Helper: Accessibility revoked, stopping engine")
            self.engine.stop()
        }
        accessibility.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }
}
