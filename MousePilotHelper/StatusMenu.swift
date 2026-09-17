// StatusMenu.swift
// MousePilot Helper — optional menu bar item (ports Helper/UI/MenuBarItem/MenuBarItem.swift).

import AppKit
import MousePilotShared

@MainActor
final class StatusMenu: NSObject {

    private let configStore: ConfigStore
    private var statusItem: NSStatusItem?
    private let scrollingItem = NSMenuItem(title: "Scrolling", action: #selector(toggleScrolling), keyEquivalent: "")
    private let buttonsItem = NSMenuItem(title: "Buttons", action: #selector(toggleButtons), keyEquivalent: "")

    init(configStore: ConfigStore) {
        self.configStore = configStore
        super.init()
    }

    func update(config: MousePilotConfig) {
        if config.general.showMenuBarItem {
            if statusItem == nil { create() }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
        scrollingItem.state = config.general.scrollingEnabled ? .on : .off
        buttonsItem.state = config.general.buttonsEnabled ? .on : .off
    }

    private func create() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MousePilotStatusItem"
        item.button?.image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "MousePilot")
        let menu = NSMenu()
        menu.autoenablesItems = false
        scrollingItem.target = self
        buttonsItem.target = self
        menu.addItem(scrollingItem)
        menu.addItem(buttonsItem)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open MousePilot…", action: #selector(openMainApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleScrolling() {
        configStore.update { $0.general.scrollingEnabled.toggle() }
    }

    @objc private func toggleButtons() {
        configStore.update { $0.general.buttonsEnabled.toggle() }
    }

    @objc private func openMainApp() {
        let url = Bundle.main.bundleURL.appendingPathComponent(MPConstants.mainAppRelativePathFromHelper).standardizedFileURL
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
