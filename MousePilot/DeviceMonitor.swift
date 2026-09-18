// DeviceMonitor.swift
// MousePilot — the live device list and the watcher that marks the mouse in the user's hand.

import Foundation
import AppKit

@MainActor
@Observable
final class DeviceMonitor {

    private(set) var devices: [PointerDevice] = []
    /// The device the most recent event came from.
    private(set) var activeDeviceID: UInt64?

    private var pollTask: Task<Void, Never>?
    private var eventMonitor: Any?

    /// Matches AppModel's status poll. Fast enough that plugging a mouse in feels immediate, slow
    /// enough to be free — and it keeps the battery reading current.
    private static let pollInterval = Duration.seconds(2)

    /// CGEventField 87 — the IORegistry entry id of the sending device. The same field the engine
    /// keys per-device click cycles on; see EventUtility.kMPCGEventFieldSenderID. The app target
    /// can't import MousePilotEngine, so the number is repeated here rather than shared.
    private static let senderIDField: UInt32 = 87

    /// Pointer movement is the signal that always arrives. A button past the right button is
    /// swallowed by the helper's tap when it has an assignment, and scroll events the engine
    /// re-synthesizes carry no sender id, so neither can be relied on on its own.
    private static let activityMask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    // MARK: Lifecycle

    /// Idempotent: the view starts the monitor on appear and again whenever the window becomes key.
    func start() {
        startPolling()
        startEventMonitor()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        stopEventMonitor()
    }

    func reload() {
        devices = DeviceCatalog.connectedDevices()
        if let activeDeviceID, !devices.contains(where: { $0.id == activeDeviceID }) {
            self.activeDeviceID = nil
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        reload()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: DeviceMonitor.pollInterval)
                guard !Task.isCancelled, let self else { return }
                reload()
            }
        }
    }

    // MARK: Event monitor

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        // Without this the window is never sent mouse-moved events, and movement is the one signal
        // that reaches the app whatever the helper is doing.
        NSApp.keyWindow?.acceptsMouseMovedEvents = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: DeviceMonitor.activityMask) { [weak self] event in
            self?.note(event)
            // Observation only: the event is always passed on untouched.
            return event
        }
    }

    private func stopEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    /// A sender id that names no listed device is ignored. It happens for synthesized events, and
    /// the only honest response is to leave the previous badge where it is.
    private func note(_ event: NSEvent) {
        guard let field = CGEventField(rawValue: DeviceMonitor.senderIDField),
              let raw = event.cgEvent?.getIntegerValueField(field)
        else { return }
        let senderID = UInt64(bitPattern: raw)
        guard let device = PointerDeviceList.device(forSenderID: senderID, in: devices) else { return }
        activeDeviceID = device.id
    }
}
