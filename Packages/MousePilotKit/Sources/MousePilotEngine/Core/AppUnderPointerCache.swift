// AppUnderPointerCache.swift
// MousePilot Engine — memoizes "which app is under the pointer", which is far too slow to ask twice.
// No Mac Mouse Fix counterpart: MMF asks the window list every time.

import Foundation
import AppKit
import CoreGraphics

/// Caches `EventUtility.bundleIDOfApp(at:)`.
///
/// The underlying lookup copies the whole on-screen window list — measured at ~0.3–0.5 ms of
/// synchronous IPC to the WindowServer, and the copy itself is essentially all of it, so there is
/// nothing to win by parsing the result faster. That is a long time to spend inside an event tap
/// callback, where it stalls input for *every* app, not just ours.
///
/// The answer can only change if the pointer moves or the window layout changes, so we memoize it
/// and invalidate on both. Scrolling a page in bursts — the common case — parks the pointer in one
/// spot, so every sequence after the first is free.
///
/// Engine-thread confined, like the rest of the engine. The workspace and display notifications
/// arrive on other threads and hop via `thread.perform` instead of taking a lock, so the cached
/// state is never touched from two threads.
///
/// Known staleness: a window can move, resize, close or open under a stationary pointer without any
/// of the observed notifications firing — another app animating a window into place, say. The cost
/// is one scroll sequence resolved against the wrong profile, and the next sequence self-corrects.
final class AppUnderPointerCache {

    private unowned let thread: EngineThread

    /// Pointer location the cached answer was looked up at, floored to a whole pixel. `nil` means
    /// "no valid entry" — invalidation just clears it.
    private var cachedPoint: CGPoint?
    private var cachedBundleID: String?

    private var observers: [NSObjectProtocol] = []
    private var isObserving = false

    /// Number of times the underlying window-list walk actually ran. Only the tests read it; it is
    /// the one way to observe a cache that is otherwise transparent by design.
    private(set) var lookupCount = 0

    init(thread: EngineThread) {
        self.thread = thread
    }

    // MARK: Lookup

    /// Bundle identifier of the app owning the frontmost normal-level window under the pointer.
    func bundleID(event: CGEvent? = nil) -> String? {
        thread.assertOnEngineThread()

        let point = EventUtility.pointerLocation(event: event)
        // Compared exactly rather than with a tolerance: a tolerance would let the pointer cross a
        // window edge without us noticing, which is the one error this cache must not make.
        let key = CGPoint(x: floor(point.x), y: floor(point.y))
        if let cachedPoint, cachedPoint == key { return cachedBundleID }

        let result = EventUtility.bundleIDOfApp(at: point)
        lookupCount += 1
        cachedPoint = key
        cachedBundleID = result
        return result
    }

    func invalidate() {
        thread.assertOnEngineThread()
        cachedPoint = nil
        cachedBundleID = nil
    }

    // MARK: Invalidation sources

    func startObserving() {
        thread.assertOnEngineThread()
        guard !isObserving else { return }
        isObserving = true

        // Anything that can put a different app's window under a stationary pointer. Window moves
        // within one app are deliberately not covered — see the note on staleness above.
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        let center = NSWorkspace.shared.notificationCenter
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.thread.perform { self.invalidate() }
            }
            observers.append(observer)
        }

        CGDisplayRegisterReconfigurationCallback(AppUnderPointerCache.displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    func stopObserving() {
        thread.assertOnEngineThread()
        guard isObserving else { return }
        isObserving = false

        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()

        CGDisplayRemoveReconfigurationCallback(AppUnderPointerCache.displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        invalidate()
    }

    /// A resolution or arrangement change moves every window, so the pointer can land somewhere new
    /// without moving at all.
    private static let displayReconfigured: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        // Fires twice per change; the "before" pass still describes the old layout.
        if flags.contains(.beginConfigurationFlag) { return }
        let cache = Unmanaged<AppUnderPointerCache>.fromOpaque(userInfo).takeUnretainedValue()
        cache.thread.perform { cache.invalidate() }
    }
}
