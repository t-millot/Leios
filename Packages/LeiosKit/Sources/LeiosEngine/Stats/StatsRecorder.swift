// StatsRecorder.swift
// Leios Engine — the usage-statistics accumulator. Lives on the engine thread; counts and nothing else.

import Foundation
import AppKit
import CoreGraphics
import LeiosShared

/// Where every counted event lands first.
///
/// The whole design of the statistics is in this class's constraints. It is confined to the engine
/// thread, so it needs no lock. It never reads the wall clock — `StatsFlusher` decides which hour a
/// batch belongs to, once a minute, instead of every call site asking `Date()` millions of times.
/// It never touches the filesystem. And every `record…` method is a handful of additions, so the
/// cost of statistics on a scroll tick is a few instructions rather than anything worth measuring.
final class StatsRecorder {

    private unowned let thread: EngineThread

    /// Whether anything is counted at all. `SwitchMaster` sets it from `collectStatistics`.
    ///
    /// The switch has to be here and not only on the tap: the tap covers raw input, but scroll
    /// output, actions and drags are recorded from inside the engine's own subsystems, which run
    /// whether or not statistics do. Gating in one place is what makes the switch mean what it says.
    private var isEnabled = true

    /// The batch being filled. `StatsTotals` is used directly rather than a packed mirror of it:
    /// the hot paths (scroll ticks, drag deltas) only touch its scalars, and the dictionary paths
    /// run at click rate, where `String(4)` is a tagged small string and costs no allocation.
    private var batch = StatsTotals()

    // Click-level recognition. The window server assigns multi-click state downstream of the HID
    // tap this reads, so the level is derived here instead: same rule, same interval, applied to
    // every button uniformly rather than only to the ones the engine has a mapping for.
    private var lastClickButton = 0
    private var lastClickTime: CFTimeInterval = -.infinity
    private var lastClickLocation = CGPoint.zero
    private var clickLevel = 0
    /// Cached rather than asked per click: `NSEvent.doubleClickInterval` reads a user default.
    private var multiClickInterval = NSEvent.doubleClickInterval
    /// How far the pointer may move between presses and still make a double click. The window
    /// server's own slop is not public; this matches what a user would call "the same spot".
    private static let multiClickSlop = 5.0

    /// End of a scroll sequence, in engine time. The gap is `StatsCounters.sequenceGap`, which is
    /// the engine's own `consecutiveScrollTickIntervalMax` — see the note there on why it is not
    /// `ScrollController.sequenceGap`.
    private var lastScrollTickTime: CFTimeInterval = -.infinity

    init(thread: EngineThread) {
        self.thread = thread
    }

    func setEnabled(_ on: Bool) {
        thread.assertOnEngineThread()
        isEnabled = on
    }

    /// Re-reads the settings the recogniser depends on. Called from `configChanged`, so a change
    /// to the double-click speed in System Settings is picked up at the next configuration reload
    /// rather than costing a lookup per click.
    func refreshSystemSettings() {
        thread.assertOnEngineThread()
        multiClickInterval = NSEvent.doubleClickInterval
    }

    /// Hands over what has been counted so far and starts a new batch.
    func drain() -> StatsTotals {
        thread.assertOnEngineThread()
        defer { batch = StatsTotals() }
        return batch
    }

    /// Throws away the current batch — used when statistics are switched off mid-flight, so the
    /// counts from before the switch do not arrive after it.
    func discard() {
        thread.assertOnEngineThread()
        batch = StatsTotals()
        clickLevel = 0
        lastClickTime = -.infinity
        lastScrollTickTime = -.infinity
    }

    // MARK: Scroll

    /// One scroll event as it arrived from the device, before Leios touched it.
    ///
    /// `deltaAxis1` is vertical and `deltaAxis2` horizontal, in points, with the sign CoreGraphics
    /// gives them: positive is up and left.
    func recordScrollInput(deltaAxis1: Int64, deltaAxis2: Int64, isContinuous: Bool, at time: CFTimeInterval) {
        thread.assertOnEngineThread()
        guard isEnabled else { return }

        if isContinuous {
            // A trackpad or a Magic Mouse. Kept apart from the wheel figures, which it would
            // otherwise dominate: one swipe is dozens of these.
            batch.counters.continuousEvents += 1
            batch.counters.continuousPoints += Double(abs(deltaAxis1) + abs(deltaAxis2))
            return
        }

        if time - lastScrollTickTime > StatsCounters.sequenceGap {
            batch.counters.scrollSequences += 1
        }
        lastScrollTickTime = time

        if deltaAxis1 > 0 {
            batch.counters.inTicksUp += 1
            batch.counters.inPointsUp += Double(deltaAxis1)
        } else if deltaAxis1 < 0 {
            batch.counters.inTicksDown += 1
            batch.counters.inPointsDown += Double(-deltaAxis1)
        }
        if deltaAxis2 > 0 {
            batch.counters.inTicksLeft += 1
            batch.counters.inPointsLeft += Double(deltaAxis2)
        } else if deltaAxis2 < 0 {
            batch.counters.inTicksRight += 1
            batch.counters.inPointsRight += Double(-deltaAxis2)
        }
    }

    /// Points the engine actually scrolled, after acceleration. Called once per tick when smooth
    /// scrolling is off and once per animation frame when it is on, which is the delivered
    /// distance either way — including momentum.
    func recordScrollOutput(points: Int64, direction: MFDirection) {
        thread.assertOnEngineThread()
        guard isEnabled else { return }
        let distance = Double(abs(points))
        switch direction {
        case .up: batch.counters.outPointsUp += distance
        case .down: batch.counters.outPointsDown += distance
        case .left: batch.counters.outPointsLeft += distance
        case .right: batch.counters.outPointsRight += distance
        case .none: break
        }
    }

    // MARK: Buttons

    /// One press of a mouse button, straight off the device. Every button, mapped or not.
    func recordClick(button: Int, at location: CGPoint, time: CFTimeInterval) {
        thread.assertOnEngineThread()
        guard isEnabled else { return }

        let sameSpot = abs(location.x - lastClickLocation.x) <= Self.multiClickSlop
            && abs(location.y - lastClickLocation.y) <= Self.multiClickSlop
        if button == lastClickButton, sameSpot, time - lastClickTime <= multiClickInterval {
            clickLevel += 1
        } else {
            clickLevel = 1
        }
        lastClickButton = button
        lastClickTime = time
        lastClickLocation = location

        batch.counters.clicks += 1
        var counts = batch.buttons[String(button)] ?? StatsButtonCounts()
        counts.clicks += 1
        switch clickLevel {
        case 2:
            batch.counters.doubleClicks += 1
            counts.doubleClicks += 1
        case 3...:
            batch.counters.tripleClicks += 1
            counts.tripleClicks += 1
        default:
            break
        }
        batch.buttons[String(button)] = counts
    }

    /// An action the engine fired for a button, once per trigger.
    func recordButtonAction(button: Int, duration: ButtonTriggerDuration, action: Action) {
        thread.assertOnEngineThread()
        guard isEnabled else { return }
        batch.counters.actions += 1
        var counts = batch.buttons[String(button)] ?? StatsButtonCounts()
        counts.actions += 1
        if duration == .hold {
            batch.counters.holds += 1
            counts.holds += 1
        }
        batch.buttons[String(button)] = counts
        batch.actions[action.statsKey, default: 0] += 1
    }

    // MARK: Drags

    /// A drag that passed the movement threshold and became a real gesture.
    func recordDragStart(gesture: MouseDragGesture) {
        thread.assertOnEngineThread()
        guard isEnabled else { return }
        batch.counters.dragStarts += 1
        var counts = batch.drags[gesture.rawValue] ?? StatsDragCounts()
        counts.starts += 1
        batch.drags[gesture.rawValue] = counts
    }

    /// Pointer path length and duration of a drag that has just ended.
    func recordDragEnd(gesture: MouseDragGesture, points: Double, seconds: Double) {
        thread.assertOnEngineThread()
        guard isEnabled else { return }
        batch.counters.dragPoints += points
        batch.counters.dragSeconds += seconds
        var counts = batch.drags[gesture.rawValue] ?? StatsDragCounts()
        counts.points += points
        counts.seconds += seconds
        batch.drags[gesture.rawValue] = counts
    }
}
