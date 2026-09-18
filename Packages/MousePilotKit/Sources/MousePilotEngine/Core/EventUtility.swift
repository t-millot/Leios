// EventUtility.swift
// MousePilot Engine — CGEvent helpers (ports Helper/Utility/EventUtility.m and HelperUtility.m).
// Derived from Mac Mouse Fix, MMF License.

import Foundation
import AppKit
import CoreGraphics
import CPrivateShim

/// CGEventField 87 carries the IORegistry entry id of the sending device.
let kMPCGEventFieldSenderID: UInt32 = 87

extension CGEvent {
    @inline(__always) func setInt(_ field: UInt32, _ value: Int64) {
        setIntegerValueField(CGEventField(rawValue: field)!, value: value)
    }
    @inline(__always) func setDouble(_ field: UInt32, _ value: Double) {
        setDoubleValueField(CGEventField(rawValue: field)!, value: value)
    }
    @inline(__always) func getInt(_ field: UInt32) -> Int64 {
        getIntegerValueField(CGEventField(rawValue: field)!)
    }
    /// Timestamp in seconds (mach time base).
    var timestampSeconds: CFTimeInterval {
        MPMachTimeToSeconds(timestamp)
    }
    var senderID: UInt64 {
        UInt64(bitPattern: getInt(kMPCGEventFieldSenderID))
    }
}

enum EventUtility {

    /// 16.16 fixed point, rounded (real scroll wheel events look like this).
    static func fixedScrollDelta(_ scrollDelta: Double) -> Int64 {
        Int64((scrollDelta * 65536).rounded())
    }

    /// Scroll events posted by the Wacom userspace driver must be left alone.
    static func isWacomEvent(_ event: CGEvent) -> Bool {
        let senderPid = event.getIntegerValueField(.eventSourceUnixProcessID)
        if senderPid == 0 { return false }
        guard let path = executablePath(forPid: pid_t(senderPid)) else { return false }
        return (path as NSString).lastPathComponent.lowercased().contains("wacom")
    }

    static func executablePath(forPid pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if len <= 0 { return nil }
        return String(cString: buffer)
    }

    // MARK: Pointer location

    static func pointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func pointerLocation(event: CGEvent?) -> CGPoint {
        event?.location ?? pointerLocation()
    }

    static func roundedPointerLocation(event: CGEvent? = nil) -> CGPoint {
        let p = pointerLocation(event: event)
        return CGPoint(x: floor(p.x), y: floor(p.y))
    }

    // MARK: Display under pointer

    static func display(at point: CGPoint) -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 1)
        var count: UInt32 = 0
        let err = CGGetDisplaysWithPoint(point, 1, &displays, &count)
        guard err == .success, count == 1 else { return nil }
        // Use the primary display of the mirror set.
        return CGDisplayPrimaryDisplay(displays[0])
    }

    static func displayUnderPointer(event: CGEvent?) -> CGDirectDisplayID {
        display(at: pointerLocation(event: event)) ?? CGMainDisplayID()
    }

    static func modifierFlags(event: CGEvent? = nil) -> CGEventFlags {
        if let event { return event.flags }
        return CGEvent(source: nil)?.flags ?? []
    }

    // MARK: App under pointer

    /// Bundle identifier of the app owning the frontmost normal-level window at `point`.
    /// Uses the window list (no AppKit main-thread requirement).
    ///
    /// Copying the window list costs ~0.3–0.5 ms of synchronous IPC, which is far too long to spend
    /// in an event tap callback. Engine code goes through `AppUnderPointerCache`, never here.
    static func bundleIDOfApp(at point: CGPoint) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPid else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if bounds.contains(point) {
                return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
        }
        return nil
    }

}
