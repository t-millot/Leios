// PointerFreeze.swift
// Leios Engine — pins the real pointer during drag gestures and optionally draws a moving "puppet" cursor.
// Ports Helper/Utility/PointerFreeze.m. Derived from Mac Mouse Fix, MMF License.

import Foundation
import AppKit
import CoreGraphics
import QuartzCore
import CPrivateShim

final class PointerFreeze {

    private enum SuppressionInterval {
        case zero, forWarping, forStoppingCursor, forUnfreezingPointerDuringFlick, `default`
    }

    /// Ports `GeneralConfig.mouseMovingMaxIntervalSmall`.
    static let mouseMovingMaxIntervalSmall: CFTimeInterval = 0.04

    private unowned let thread: EngineThread
    private var tap: EventTap?
    private(set) var isFrozen = false
    private var origin: CGPoint = .zero
    private var keepPointerMoving = false
    private var puppetPosition: CGPoint = .zero
    /// Bounds of the display the puppet cursor is confined to, taken once per freeze rather than
    /// asked of CoreGraphics on every one of the up-to-8000 mouse reports a second it moves on.
    private var displayBounds: CGRect = .zero
    private var lastEventTimestamp: CFTimeInterval = 0
    private var lastEventDelta: Int64 = 0
    private var previousInterval: SuppressionInterval = .default
    private var defaultSuppressionInterval: CFTimeInterval = 0.25
    private var cursorHidden = false
    private var cursorSettable = false

    // Main-thread state
    private let puppetView = MainActorBox<NSImageView?>(nil)
    private let puppetDraws = PuppetDrawQueue()

    init(thread: EngineThread) {
        self.thread = thread
        DispatchQueue.main.async { [puppetView] in
            MainActor.assumeIsolated { puppetView.value = NSImageView() }
        }
    }

    func createTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
        tap = EventTap(name: "pointerFreeze", mask: mask, runLoop: thread.runLoop) { [unowned self] _, _, event in
            self.handleMouseMoved(event)
            return Unmanaged.passUnretained(event)
        }
    }

    /// Lets a background process hide/set the cursor.
    func makeCursorSettable() {
        if cursorSettable { return }
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        cursorSettable = true
    }

    // MARK: Freeze

    /// Pin the real pointer, hide it and draw a puppet cursor that follows the mouse.
    func freezeEventDispatchPoint(at origin: CGPoint) {
        freeze(at: origin, keepPointerMoving: true)
    }

    /// Pin the real pointer in place.
    func freezePointer(at origin: CGPoint) {
        freeze(at: origin, keepPointerMoving: false)
    }

    private func freeze(at origin: CGPoint, keepPointerMoving: Bool) {
        thread.assertOnEngineThread()
        self.origin = origin
        self.keepPointerMoving = keepPointerMoving
        isFrozen = true
        setSuppressionInterval(.forStoppingCursor)
        tap?.enable(true)
        if keepPointerMoving {
            puppetPosition = origin
            displayBounds = CGDisplayBounds(EventUtility.display(at: origin) ?? CGMainDisplayID())
            makeCursorSettable()
            let pos = puppetPosition
            puppetDraws.reset()
            // Draw before hiding, so there is never a moment with neither the real nor the puppet
            // cursor on screen. `showCursor` goes through the same queue, which is what keeps the
            // hide and the show in order.
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    drawPuppet(at: pos, fresh: true)
                }
                CGDisplayHideCursor(CGMainDisplayID())
            }
            cursorHidden = true
        }
    }

    private func handleMouseMoved(_ event: CGEvent) {
        guard isFrozen else { return }
        var dx: Int64 = -1
        var dy: Int64 = -1
        if keepPointerMoving {
            dx = event.getIntegerValueField(.mouseEventDeltaX)
            dy = event.getIntegerValueField(.mouseEventDeltaY)
        }
        lastEventTimestamp = CACurrentMediaTime()
        // Deviation from Mac Mouse Fix, which computes `llabs(MAX(dx, dy))`: for a move that is
        // negative on both axes that takes the magnitude of the *smaller* motion, so a fast
        // up-and-left flick reads as a stationary pointer and `unfreeze` skips the flick suppression
        // interval. Both axes are magnitudes here before the max is taken.
        lastEventDelta = max(abs(dx), abs(dy))
        CGWarpMouseCursorPosition(origin)
        if keepPointerMoving {
            var pos = puppetPosition
            pos.x += Double(dx)
            pos.y += Double(dy)
            pos.x = clip(pos.x, displayBounds.minX, displayBounds.maxX - 1)
            pos.y = clip(pos.y, displayBounds.minY, displayBounds.maxY - 1)
            puppetPosition = pos
            // A high-report-rate mouse sends up to 8000 of these a second, far more often than the
            // display can show them. Coalesce: one redraw in flight at a time, always rendering the
            // newest position, instead of one main-thread wakeup per report.
            if puppetDraws.post(pos) {
                DispatchQueue.main.async { [self] in
                    let latest = puppetDraws.take()
                    MainActor.assumeIsolated { drawPuppet(at: latest, fresh: false) }
                }
            }
        }
    }

    // MARK: Unfreeze

    func unfreeze() {
        thread.assertOnEngineThread()
        guard isFrozen else { return }
        isFrozen = false
        let timeSinceLastEvent = CACurrentMediaTime() - lastEventTimestamp
        let pointerIsMoving = timeSinceLastEvent < PointerFreeze.mouseMovingMaxIntervalSmall && lastEventDelta > 0
        tap?.enable(false)

        let warpDestination: CGPoint
        if keepPointerMoving {
            setSuppressionInterval(.forWarping)
            warpDestination = puppetPosition
        } else {
            setSuppressionInterval(pointerIsMoving ? .forUnfreezingPointerDuringFlick : .zero)
            warpDestination = origin
        }
        CGWarpMouseCursorPosition(warpDestination)
        if keepPointerMoving {
            showCursor()
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { undrawPuppet() }
            }
        }
        setSuppressionInterval(.default)
    }

    /// Safe to call from any state; restores the cursor and the global suppression interval.
    func emergencyUnfreeze() {
        isFrozen = false
        tap?.enable(false)
        showCursor()
        setSuppressionInterval(.default)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { undrawPuppet() }
        }
    }

    func invalidate() {
        emergencyUnfreeze()
        tap?.invalidate()
        tap = nil
    }

    /// Hiding is queued on the main thread (see `freeze`), so showing has to take the same queue.
    /// Running it inline on the engine thread instead lets a drag that ends before the hide has been
    /// serviced show first and hide second, leaving the pointer invisible for the rest of the session.
    /// If the process dies before this runs, the WindowServer releases the hide with the connection.
    private func showCursor() {
        guard cursorHidden else { return }
        cursorHidden = false
        makeCursorSettable()
        DispatchQueue.main.async {
            CGDisplayShowCursor(CGMainDisplayID())
            CGDisplayShowCursor(CGMainDisplayID()) // twice for good measure
        }
    }

    // MARK: Suppression interval (process-global side effect — always restored)

    private func setSuppressionInterval(_ mfInterval: SuppressionInterval) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        if previousInterval == .default {
            defaultSuppressionInterval = src.localEventsSuppressionInterval
        }
        let interval: CFTimeInterval
        switch mfInterval {
        case .forStoppingCursor: interval = 0.07
        case .zero: interval = 0.0
        case .default: interval = defaultSuppressionInterval
        case .forWarping: interval = 0.0
        case .forUnfreezingPointerDuringFlick: interval = 0.15
        }
        src.localEventsSuppressionInterval = interval
        previousInterval = mfInterval
    }

    // MARK: Puppet cursor (main thread)

    @MainActor
    private func drawPuppet(at loc: CGPoint, fresh: Bool) {
        guard let view = puppetView.value else { return }
        let cursor = NSCursor.arrow
        let hotspot = cursor.hotSpot
        let size = cursor.image.size
        let imageLoc = CGPoint(x: loc.x - hotspot.x, y: loc.y - hotspot.y)
        let frame = NSRect(x: imageLoc.x, y: imageLoc.y, width: size.width, height: size.height)
        let frameUnflipped = PointerFreeze.quartzToCocoa(frame)
        if fresh {
            view.image = cursor.image
            let screen = NSScreen.screens.first { $0.frame.contains(frameUnflipped.origin) } ?? NSScreen.screens.first
            guard let screen else { return }
            ScreenDrawer.shared.draw(view: view, atFrame: frameUnflipped, onScreen: screen)
            view.alphaValue = 1
        } else {
            ScreenDrawer.shared.move(view: view, toOrigin: frameUnflipped.origin)
        }
    }

    @MainActor
    private func undrawPuppet() {
        guard let view = puppetView.value else { return }
        ScreenDrawer.shared.undraw(view: view)
    }

    @MainActor
    private static func quartzToCocoa(_ rect: NSRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }
}

/// Coalesces puppet-cursor redraws between the engine thread, which produces a position per mouse
/// report, and the main thread, which can only draw once per frame.
private final class PuppetDrawQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var position: CGPoint = .zero

    /// Records the newest position. Returns true when the caller has to schedule a draw, which is
    /// only when none is already in flight.
    func post(_ newPosition: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        position = newPosition
        if pending { return false }
        pending = true
        return true
    }

    /// The newest recorded position; lets the next `post` schedule again.
    func take() -> CGPoint {
        lock.lock(); defer { lock.unlock() }
        pending = false
        return position
    }

    func reset() {
        lock.lock(); pending = false; lock.unlock()
    }
}

/// Box for main-thread-only state that is created asynchronously.
final class MainActorBox<T>: @unchecked Sendable {
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { _value }
        set { _value = newValue }
    }
}
