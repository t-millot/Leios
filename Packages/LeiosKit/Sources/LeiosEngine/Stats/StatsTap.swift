// StatsTap.swift
// Leios Engine — a listen-only tap that counts raw mouse input for the usage statistics.

import Foundation
import CoreGraphics
import LeiosShared

/// Counts what the user's hand did, as opposed to what Leios did about it.
///
/// A tap of its own, rather than a few lines inside the taps that already exist, because those are
/// switched off most of the time: `SwitchMaster` disarms the scroll tap whenever nothing modifies
/// scrolling, and the button tap whenever nothing is mapped. Counting there would report zero for
/// a default configuration, which is exactly the configuration most people run.
///
/// Two things keep it honest, and both matter:
///
/// - It is `.listenOnly`, so it cannot modify, delay or swallow anything. Whatever this class does
///   wrong, it cannot change what the user's mouse does.
/// - It sits at `.cghidEventTap`, upstream of everything the engine itself posts (which all goes to
///   `.cgSessionEventTap`), so Leios's own synthesized scrolls and clicks are invisible to it and
///   nothing is counted twice.
///
/// It must also be the **last** tap created, because `.headInsertEventTap` puts the newest tap at
/// the head of the chain: only from there does it see a scroll event before `ScrollController`
/// swallows it. See the call site in `EngineSubsystems.start()`.
final class StatsTap {

    private unowned let thread: EngineThread
    private unowned let recorder: StatsRecorder

    private var tap: EventTap?
    var isReceiving: Bool { tap?.isEnabled ?? false }

    private static let mask: CGEventMask =
        .init(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)

    init(thread: EngineThread, recorder: StatsRecorder) {
        self.thread = thread
        self.recorder = recorder
    }

    func createTap() {
        guard tap == nil else { return }
        tap = EventTap(name: "stats",
                       options: .listenOnly,
                       mask: Self.mask,
                       runLoop: thread.runLoop) { [unowned self] _, type, event in
            self.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
    }

    /// Turning the tap off deliberately does **not** throw away what has been counted.
    ///
    /// It used to, on the reasoning that counts from before the switch should not arrive after it.
    /// That was wrong twice over. `SwitchMaster.disableAll()` runs on the way out of
    /// `EngineSubsystems.stop()`, immediately before the flusher's final write — so discarding
    /// here silently lost every count since the last flush on any clean shutdown, which is the one
    /// case that write exists for. And for the statistics switch itself, counts gathered while it
    /// was on are counts the user asked for; the button that throws them away is Reset.
    func setReceiving(_ on: Bool) {
        tap?.enable(on)
    }

    func invalidate() {
        tap?.invalidate()
        tap = nil
    }

    // MARK: Tap callback

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .scrollWheel:
            recorder.recordScrollInput(deltaAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                                       deltaAxis2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                                       isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                                       at: event.timestampSeconds)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Engine numbering: the config and `LeiosConstants.minButton` count from 1, while
            // `mouseEventButtonNumber` counts from 0.
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
            recorder.recordClick(button: button, at: event.location, time: event.timestampSeconds)
        default:
            break
        }
    }
}
