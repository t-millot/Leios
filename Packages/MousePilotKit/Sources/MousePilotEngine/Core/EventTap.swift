// EventTap.swift
// MousePilot Engine — CGEventTap wrapper. Ports Mac Mouse Fix's ModificationUtility.createEventTap…
// Taps are created disabled and scheduled on the engine run loop; every tap re-enables itself on
// kCGEventTapDisabledByTimeout.

import Foundation
import CoreGraphics

final class EventTap {

    typealias Callback = (_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>?

    let name: String
    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?
    private let runLoop: CFRunLoop
    private let callback: Callback
    private(set) var isEnabled = false
    private(set) var isValid = false
    /// Set when macOS disabled the tap because of user input (e.g. secure input); informational.
    private(set) var wasDisabledByUserInput = false

    init?(name: String,
          location: CGEventTapLocation = .cghidEventTap,
          placement: CGEventTapPlacement = .headInsertEventTap,
          options: CGEventTapOptions = .defaultTap,
          mask: CGEventMask,
          runLoop: CFRunLoop,
          callback: @escaping Callback) {
        self.name = name
        self.runLoop = runLoop
        self.callback = callback

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: location,
                                           place: placement,
                                           options: options,
                                           eventsOfInterest: mask,
                                           callback: EventTap.trampoline,
                                           userInfo: refcon) else {
            Log.engine.error("EventTap \(name): CGEventTapCreate failed (no Accessibility permission?)")
            return nil
        }
        machPort = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
        source = src
        CFRunLoopAddSource(runLoop, src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: false)
        isValid = true
    }

    deinit { invalidate() }

    private static let trampoline: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout:
            Log.engine.warning("EventTap \(tap.name): disabled by timeout, re-enabling")
            if let port = tap.machPort, tap.isEnabled { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            tap.wasDisabledByUserInput = true
            Log.engine.warning("EventTap \(tap.name): disabled by user input")
            return Unmanaged.passUnretained(event)
        default:
            return tap.callback(proxy, type, event)
        }
    }

    func enable(_ on: Bool) {
        guard let port = machPort, isValid else { return }
        if on == isEnabled { return }
        isEnabled = on
        wasDisabledByUserInput = false
        CGEvent.tapEnable(tap: port, enable: on)
    }

    func invalidate() {
        guard isValid else { return }
        isValid = false
        isEnabled = false
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            if let src = source { CFRunLoopRemoveSource(runLoop, src, .commonModes) }
            CFMachPortInvalidate(port)
        }
        source = nil
        machPort = nil
    }
}
