// TouchSimulator.swift
// MousePilot Engine — synthesized trackpad gestures: navigation swipe, smart zoom, rotation, magnification, dock swipe.
// Ports Helper/Core/Touch/TouchSimulator.m. Derived from Mac Mouse Fix, MMF License.
// Credits (from Mac Mouse Fix): the navigation-swipe technique originates in natevw's "CalfTrail Touch" reverse engineering.

import Foundation
import CoreGraphics
import QuartzCore
import CPrivateShim

enum DockSwipeType: Int64 {
    /// Spaces / page swipe
    case horizontal = 1
    /// Mission Control / App Exposé
    case vertical = 2
    /// Show Desktop / Launchpad
    case pinch = 3
}

enum NavigationSwipeDirection: Int64 {
    case left = 4   // kIOHIDSwipeLeft  (1 << 2)
    case right = 8  // kIOHIDSwipeRight (1 << 3)
}

final class TouchSimulator {

    private unowned let thread: EngineThread

    init(thread: EngineThread) {
        self.thread = thread
    }

    // MARK: Simple gestures

    /// Go back / forward in apps like Safari.
    func postNavigationSwipe(direction: NavigationSwipeDirection) {
        guard let e = CGEvent(source: nil) else { return }
        e.setInt(55, 29)   // NSEventTypeGesture
        e.setInt(110, 16)  // kIOHIDEventTypeNavigationSwipe
        e.setInt(132, IOHIDPhase.began.rawValue)
        e.setInt(115, direction.rawValue)
        e.post(tap: .cghidEventTap)
        e.setInt(115, 0)   // kIOHIDSwipeNone
        e.setInt(132, IOHIDPhase.ended.rawValue)
        e.post(tap: .cghidEventTap)
    }

    func postSmartZoom() {
        guard let e = CGEvent(source: nil) else { return }
        e.setInt(55, 29)   // NSEventTypeGesture
        e.setInt(110, 22)  // kIOHIDEventTypeZoomToggle
        e.post(tap: .cghidEventTap)
    }

    func postRotation(_ rotation: Double, phase: IOHIDPhase) {
        guard let e = CGEvent(source: nil) else { return }
        e.setInt(55, 29)
        e.setInt(110, 5)   // kIOHIDEventTypeRotation
        e.setDouble(114, rotation)
        e.setInt(132, phase.rawValue)
        e.post(tap: .cghidEventTap)
    }

    func postMagnification(_ magnification: Double, phase: IOHIDPhase) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = CGEventType(rawValue: 29)!  // NSEventTypeGesture
        e.setInt(110, 8)   // kIOHIDEventTypeZoom
        e.setInt(132, phase.rawValue)
        e.setDouble(113, magnification)
        e.post(tap: .cghidEventTap)
    }

    // MARK: Dock swipe (macOS 27 IOHIDEvent path)

    private var dockSwipeOriginOffset = 0.0
    private var dockSwipeLastDelta = 0.0
    private var dockSwipeLastPostTime: CFTimeInterval = 0
    private var dockSwipeThrottledDelta = 0.0
    private var dockSwipeResendTimers: [CFRunLoopTimer] = []
    private var loggedMissingSkyLight = false

    /// Drives Spaces / Mission Control / Show Desktop like a three- or four-finger trackpad gesture.
    /// `phase` Began → Changed… → Ended/Cancelled. Changed events are throttled to ~125 Hz (trackpad report rate).
    func postDockSwipe(delta dIn: Double, type: DockSwipeType, phase: IOHIDPhase, invertedFromDevice: Bool) {
        var d = dIn

        // Accumulate origin offset
        if phase == .began {
            dockSwipeOriginOffset = d
        } else if phase == .changed {
            if d == 0 { return }
            dockSwipeOriginOffset += d
        }

        // Throttle `changed` events: high-report-rate mice make the Dock fall behind.
        if phase == .changed {
            dockSwipeThrottledDelta += d
            let now = CACurrentMediaTime()
            if now - dockSwipeLastPostTime < (1.0 / 125.0) { return }
            dockSwipeLastPostTime = now
            d = dockSwipeThrottledDelta
            dockSwipeThrottledDelta = 0
        } else {
            dockSwipeLastPostTime = phase == .began ? CACurrentMediaTime() : 0
            dockSwipeThrottledDelta = 0
        }

        // Exit speed (macOS 27 was observed using ×300; Mac Mouse Fix ships ×100)
        var exitSpeed = 0.0
        var phase = phase
        if phase == .ended || phase == .cancelled {
            exitSpeed = dockSwipeLastDelta * 100
            // Flicked back → cancel instead of end.
            if mfsign(dockSwipeLastDelta) != mfsign(dockSwipeOriginOffset) {
                phase = .cancelled
            }
        }

        // Build IOHIDEvent (macOS 27 ignores the CGEventFields and reads the wrapped IOHIDEvent)
        let progress = invertedFromDevice ? -dockSwipeOriginOffset : dockSwipeOriginOffset
        guard let hidEvent = IOHIDEventCreate(nil, IOHIDEventType(kIOHIDEventTypeDockSwipe), MPMachAbsoluteTime(), 0) else { return }
        IOHIDEventSetPhase(hidEvent, IOHIDEventPhaseBits(phase.rawValue))
        #if DEBUG
        let encodedPhase = Int64((IOHIDEventGetEventFlags(hidEvent) >> UInt32(kIOHIDEventEventOptionPhaseShift)) & UInt32(kIOHIDEventEventPhaseMask))
        if encodedPhase != phase.rawValue {
            Log.touch.warning("IOHIDEventSetPhase did not encode phase; falling back to event flags")
            IOHIDEventSetEventFlags(hidEvent, IOOptionBits(phase.rawValue) << UInt32(kIOHIDEventEventOptionPhaseShift))
        }
        #endif
        IOHIDEventSetIntegerValue(hidEvent, IOHIDEventField(kIOHIDEventFieldDockSwipeMotion), CFIndex(type.rawValue))
        IOHIDEventSetIntegerValue(hidEvent, IOHIDEventField(kIOHIDEventFieldDockSwipeFlavor), CFIndex(kIOHIDGestureFlavorDockPrimary))
        IOHIDEventSetFloatValue(hidEvent, IOHIDEventField(kIOHIDEventFieldDockSwipeProgress), progress)

        if phase == .ended || phase == .cancelled {
            if let child = IOHIDEventCreate(nil, IOHIDEventType(kIOHIDEventTypeVelocity), MPMachAbsoluteTime(), 0) {
                IOHIDEventSetFloatValue(child, IOHIDEventField(kIOHIDEventFieldVelocityX), exitSpeed)
                IOHIDEventSetFloatValue(child, IOHIDEventField(kIOHIDEventFieldVelocityY), exitSpeed)
                IOHIDEventSetFloatValue(child, IOHIDEventField(kIOHIDEventFieldVelocityZ), 0)
                IOHIDEventAppendEvent(hidEvent, child, 0)
                MPIOHIDEventRelease(child)
            }
        }

        let cg = CGEvent(source: nil)
        if let cg {
            cg.type = CGEventType(rawValue: 30)!
            if !MPEventSetIOHIDEvent(cg, hidEvent) {
                if !loggedMissingSkyLight {
                    loggedMissingSkyLight = true
                    Log.touch.error("SLEventSetIOHIDEvent unavailable; dock swipes are disabled")
                }
                MPIOHIDEventRelease(hidEvent)
                return
            }
        }
        MPIOHIDEventRelease(hidEvent)
        guard let cg else { return }

        // Cancel pending re-sends when a new gesture starts.
        if phase == .began {
            for t in dockSwipeResendTimers { CFRunLoopTimerInvalidate(t) }
            dockSwipeResendTimers.removeAll()
        }

        cg.post(tap: .cgSessionEventTap)

        // Re-post end events after 0.2 s and 0.5 s to work around the Dock's "stuck transition" bug.
        if phase == .ended || phase == .cancelled {
            for delay in [0.2, 0.5] {
                let timer = thread.scheduleTimer(after: delay) {
                    cg.post(tap: .cgSessionEventTap)
                }
                dockSwipeResendTimers.append(timer)
            }
        }

        dockSwipeLastDelta = d
    }

    func invalidate() {
        for t in dockSwipeResendTimers { CFRunLoopTimerInvalidate(t) }
        dockSwipeResendTimers.removeAll()
    }
}
