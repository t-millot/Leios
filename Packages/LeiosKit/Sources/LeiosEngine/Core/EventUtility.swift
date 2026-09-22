// EventUtility.swift
// Leios Engine — CGEvent helpers (ports Helper/Utility/EventUtility.m and HelperUtility.m).
// Derived from Mac Mouse Fix, MMF License.

import Foundation
import AppKit
import CoreGraphics
import CPrivateShim

/// CGEventField 87 carries the IORegistry entry id of the sending device.
let kLeiosCGEventFieldSenderID: UInt32 = 87

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
    /// Timestamp in seconds since boot, on the same clock as `CACurrentMediaTime()`.
    ///
    /// `CGEventTimestamp` is **nanoseconds**, not mach ticks, so it must not go through
    /// `mach_timebase_info` the way `mach_absolute_time()` does. On Intel the two were the same
    /// number — the timebase is 1/1 there — which is why Mac Mouse Fix could convert it as a mach
    /// time and why the mistake survives being ported. On Apple silicon the timebase is 125/3, so
    /// converting it inflated every interval the engine measures by about 42×: no scroll tick was
    /// ever within `consecutiveScrollTickIntervalMax` of the one before it, so acceleration sat at
    /// its floor, fast scroll never engaged, and `ScrollController` re-resolved the app under the
    /// pointer on every tick instead of once per sequence.
    var timestampSeconds: CFTimeInterval {
        CFTimeInterval(timestamp) / 1e9
    }
    var senderID: UInt64 {
        UInt64(bitPattern: getInt(kLeiosCGEventFieldSenderID))
    }
}

enum EventUtility {

    /// 16.16 fixed point, rounded (real scroll wheel events look like this).
    static func fixedScrollDelta(_ scrollDelta: Double) -> Int64 {
        Int64((scrollDelta * 65536).rounded())
    }

    /// Whether `pid` is the Wacom userspace driver, whose scroll events must be left alone.
    ///
    /// Costs a `proc_pidpath` syscall and a 4 KB buffer, which is too much to spend on every tick —
    /// engine code goes through `AppUnderPointerCache.isWacomEvent(_:)`, which memoizes this per pid
    /// and drops the memo when an app exits. Mac Mouse Fix removed its own cache only because it had
    /// nothing watching for pid reuse.
    static func isWacomProcess(pid: pid_t) -> Bool {
        guard let path = executablePath(forPid: pid) else { return false }
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

    /// pid of the app owning the frontmost normal-level window at `point`.
    ///
    /// `point` is in the CG global display coordinate space (top-left origin), which is what
    /// `CGEvent.location` gives us — the same space the window list reports bounds in, so no flip.
    ///
    /// Prefers SkyLight's window hit test, which asks the WindowServer about one point instead of
    /// copying every window's metadata: ~37 µs against ~310 µs, measured. Falls back to the window
    /// list when SkyLight declines, so behaviour is unchanged if the private symbols ever go away.
    ///
    /// Still far too slow for an event tap callback either way — engine code goes through
    /// `AppUnderPointerCache`, never here.
    static func pidOfApp(at point: CGPoint) -> pid_t? {
        var pid: pid_t = 0
        if LeiosPidOfWindowAtPoint(point, &pid), pid != ProcessInfo.processInfo.processIdentifier {
            return pid
        }
        // Either SkyLight has no answer, or the window it found is our own overlay (`ScreenDrawer`
        // during a drag). The walk below keeps looking past our own windows, which is what we want.
        return pidOfAppViaWindowList(at: point)
    }

    /// The original window-list walk: the fallback path, and the oracle the SkyLight path is tested
    /// against.
    static func pidOfAppViaWindowList(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPid else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if bounds.contains(point) { return pid }
        }
        return nil
    }

    /// Convenience for callers with no pid cache of their own. `AppUnderPointerCache` resolves the
    /// bundle identifier itself, because `NSRunningApplication` costs about as much as the hit test.
    static func bundleIDOfApp(at point: CGPoint) -> String? {
        pidOfApp(at: point).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

    static func bundleIDOfAppViaWindowList(at point: CGPoint) -> String? {
        pidOfAppViaWindowList(at: point).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

}
