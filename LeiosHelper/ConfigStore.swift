// ConfigStore.swift
// Leios Helper — reads config.json and watches its directory for changes.

import Foundation
import LeiosShared

@MainActor
final class ConfigStore {

    private(set) var config: LeiosConfig
    var onChange: ((LeiosConfig) -> Void)?

    /// True once a read of config.json has failed. The kill switches must not write over a file
    /// this build could not parse; the app owns recovering from that.
    private(set) var loadFailed = false

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?

    init(initial: LeiosConfig, loadFailed: Bool = false) {
        config = initial
        self.loadFailed = loadFailed
    }

    func startWatching() {
        try? FileManager.default.createDirectory(at: ConfigFile.directoryURL, withIntermediateDirectories: true)
        fd = open(ConfigFile.directoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("Leios Helper: cannot watch config directory")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Re-reads the file. Returns false if it could not be parsed.
    @discardableResult
    func reload() -> Bool {
        do {
            let new = try ConfigFile.load()
            loadFailed = false
            if new != config {
                config = new
                onChange?(new)
            }
            return true
        } catch {
            loadFailed = true
            NSLog("Leios Helper: config reload failed: \(error)")
            return false
        }
    }

    /// Writes a modified config (used by the status menu kill switches) and applies it.
    func update(_ mutate: (inout LeiosConfig) -> Void) {
        guard !loadFailed else {
            NSLog("Leios Helper: refusing to write over an unreadable config")
            return
        }
        var new = config
        mutate(&new)
        guard new != config else { return }
        config = new
        do { try ConfigFile.save(new) } catch { NSLog("Leios Helper: config save failed: \(error)") }
        onChange?(new)
    }
}
