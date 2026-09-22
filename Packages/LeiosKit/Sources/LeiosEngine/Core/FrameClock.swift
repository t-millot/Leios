// FrameClock.swift
// Leios Engine — per-display frame callbacks delivered on the engine run loop.
// Replaces Mac Mouse Fix's Shared/Animation/DisplayLink.m (CVDisplayLink) with CADisplayLink.

import Foundation
import AppKit
import QuartzCore

struct FrameTiming {
    /// When the callback ran.
    var now: CFTimeInterval
    /// When the last frame was displayed.
    var lastFrame: CFTimeInterval
    /// When the frame being produced will be displayed.
    var outFrame: CFTimeInterval
    /// Latest measured frame period.
    var timeBetweenFrames: CFTimeInterval
    /// Nominal frame period of the display.
    var nominalTimeBetweenFrames: CFTimeInterval
}

protocol FrameClock: AnyObject {
    var nominalTimeBetweenFrames: CFTimeInterval { get }
    /// Adds a subscriber; the clock runs while it has subscribers. Callbacks arrive on the engine run loop.
    /// Returns false when the clock has been torn down and will never tick again, so the caller can
    /// pick a live one instead of waiting for a frame that cannot arrive.
    @discardableResult
    func subscribe(_ token: ObjectIdentifier, _ callback: @escaping (FrameTiming) -> Void) -> Bool
    func unsubscribe(_ token: ObjectIdentifier)
}

/// A CADisplayLink created on the main thread (from an NSScreen) and scheduled on the engine run loop.
final class CADisplayLinkClock: NSObject, FrameClock {

    let displayID: CGDirectDisplayID
    private var link: CADisplayLink?
    /// Subscribed to and ticked on the engine thread, but torn down from the main thread when the
    /// pool rebuilds or stops, so this one dictionary is the engine's only shared mutable state here.
    /// Callbacks are always invoked outside the lock, since a callback may subscribe or unsubscribe.
    private let lock = NSLock()
    private var subscribers: [ObjectIdentifier: (FrameTiming) -> Void] = [:] {
        didSet { callbacks = Array(subscribers.values) }
    }
    /// `subscribers.values`, kept as an array so a frame copies a reference under the lock instead
    /// of allocating a fresh array at the display's refresh rate for as long as anything animates.
    private var callbacks: [(FrameTiming) -> Void] = []

    /// Must be called on the main thread.
    init(screen: NSScreen, displayID: CGDirectDisplayID, runLoop: RunLoop) {
        self.displayID = displayID
        super.init()
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.isPaused = true
        link.add(to: runLoop, forMode: .common)
        self.link = link
    }

    var nominalTimeBetweenFrames: CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        let d = link?.duration ?? 0
        return d > 0 ? d : 1.0 / 60.0
    }

    /// True while the clock can still deliver frames. A subscriber that arrives after the pool
    /// dropped this clock would otherwise wait forever for a tick that can no longer come.
    private(set) var isValid = true

    @discardableResult
    func subscribe(_ token: ObjectIdentifier, _ callback: @escaping (FrameTiming) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isValid else { return false }
        let wasEmpty = subscribers.isEmpty
        subscribers[token] = callback
        if wasEmpty {
            link?.isPaused = false
        }
        return true
    }

    func unsubscribe(_ token: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        subscribers[token] = nil
        if subscribers.isEmpty { link?.isPaused = true }
    }

    func invalidate() {
        lock.lock()
        isValid = false
        subscribers.removeAll()
        let link = self.link
        self.link = nil
        lock.unlock()
        // Outside the lock: tearing the link down touches run loops, and nothing here needs the lock
        // once the clock is marked invalid and detached.
        link?.invalidate()
    }

    @objc private func tick(_ link: CADisplayLink) {
        lock.lock()
        let callbacks = self.callbacks
        lock.unlock()
        guard !callbacks.isEmpty else { return }
        let now = CACurrentMediaTime()
        // The link being ticked, not `self.link`, which the main thread may be clearing right now.
        let nominal = link.duration > 0 ? link.duration : 1.0 / 60.0
        let last = link.timestamp
        let target = link.targetTimestamp
        var between = target - last
        if between <= 0 { between = nominal }
        let timing = FrameTiming(now: now, lastFrame: last, outFrame: target, timeBetweenFrames: between, nominalTimeBetweenFrames: nominal)
        for callback in callbacks {
            callback(timing)
        }
    }
}

/// Owns one clock per attached display. Clocks are (re)built on the main thread; the engine thread reads them under a lock.
final class FrameClockPool {

    private let lock = NSLock()
    private var clocks: [CGDirectDisplayID: CADisplayLinkClock] = [:]
    private let engineRunLoop: RunLoop
    private var observer: NSObjectProtocol?

    init(engineRunLoop: RunLoop) {
        self.engineRunLoop = engineRunLoop
    }

    /// Main thread.
    func start() {
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    /// Main thread.
    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        lock.lock()
        let old = clocks
        clocks = [:]
        lock.unlock()
        for c in old.values { c.invalidate() }
    }

    private func rebuild() {
        var new: [CGDirectDisplayID: CADisplayLinkClock] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            new[id] = CADisplayLinkClock(screen: screen, displayID: id, runLoop: engineRunLoop)
        }
        lock.lock()
        let old = clocks
        clocks = new
        lock.unlock()
        // Old clocks keep running for their current subscribers until those animations end; they are not reused.
        for c in old.values where c !== new[c.displayID] {
            c.unsubscribeAllLater()
        }
    }

    func clock(for display: CGDirectDisplayID) -> FrameClock? {
        lock.lock(); defer { lock.unlock() }
        if let c = clocks[display] { return c }
        return clocks[CGMainDisplayID()] ?? clocks.values.first
    }
}

private extension CADisplayLinkClock {
    /// Invalidate once the engine thread has drained current callbacks.
    func unsubscribeAllLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.invalidate()
        }
    }
}
