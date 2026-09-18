// ScrollAnalyzer.swift
// MousePilot Engine — consecutive-tick / consecutive-swipe analysis of scroll wheel input.
// Ports Helper/Core/Scroll/ScrollAnalyzer.m. Derived from Mac Mouse Fix, MMF License.

import Foundation
import QuartzCore

struct ScrollAnalysisResult {
    var consecutiveScrollTickCounter: Int
    var consecutiveScrollSwipeCounter: Double
    var scrollDirectionDidChange: Bool
    /// `Double.greatestFiniteMagnitude` means "first tick of a sequence" (not consecutive).
    var timeBetweenTicks: CFTimeInterval
    var timeBetweenTicksRaw: CFTimeInterval
}

final class ScrollAnalyzer {

    private var previousScrollTickTimeStamp: CFTimeInterval = 0
    private var previousDirection: MFDirection = .none
    private var consecutiveScrollTickCounter = 0
    private var consecutiveScrollSwipeCounter = 0
    private var consecutiveScrollSwipeCounter_ForFreeScrollWheel = 0.0
    private var ticksInCurrentConsecutiveSwipeSequence = 0
    private var consecutiveSwipeSequenceStartTime: CFTimeInterval = -1
    private let tickTimeSmoother = RollingAverage(capacity: 3)

    private func directionChanged(_ a: MFDirection, _ b: MFDirection) -> Bool {
        a != .none && b != .none && a != b
    }

    func reset() {
        previousScrollTickTimeStamp = 0
        previousDirection = .none
        consecutiveScrollTickCounter = 0
        consecutiveScrollSwipeCounter = 0
        consecutiveScrollSwipeCounter_ForFreeScrollWheel = 0
        ticksInCurrentConsecutiveSwipeSequence = 0
        consecutiveSwipeSequenceStartTime = -1
        // Deliberately not resetting the smoother here (matches Mac Mouse Fix).
    }

    /// Whether a tick at `time` would be the first of a new consecutive sequence, without changing state.
    func peekIsFirstConsecutiveTick(at time: CFTimeInterval, direction: MFDirection, config: ScrollConfig) -> Bool {
        if directionChanged(previousDirection, direction) { return true }
        let secondsSinceLastTick = time - previousScrollTickTimeStamp
        return secondsSinceLastTick > config.consecutiveScrollTickIntervalMax
    }

    /// `time` is the sending event's own timestamp. Mac Mouse Fix measures the swipe-sequence speed
    /// below against `CACurrentMediaTime()` instead, mixing the wall clock into a calculation whose
    /// other term is event-derived: same mach time base, but it picks up whatever delay the tap
    /// callback happened to be scheduled with. One clock throughout, and it is the accurate one.
    func update(tickAt time: CFTimeInterval, direction: MFDirection, config: ScrollConfig) -> ScrollAnalysisResult {
        var scrollDirectionDidChange = false
        if directionChanged(previousDirection, direction) {
            scrollDirectionDidChange = true
        }
        previousDirection = direction
        if scrollDirectionDidChange {
            reset()
            previousDirection = direction
        }

        var secondsSinceLastTick = time - previousScrollTickTimeStamp
        if secondsSinceLastTick < config.consecutiveScrollTickIntervalMin {
            secondsSinceLastTick = config.consecutiveScrollTickIntervalMin
        }

        ticksInCurrentConsecutiveSwipeSequence += 1

        if secondsSinceLastTick > config.consecutiveScrollTickIntervalMax {
            // First consecutive tick → update swipes.
            var keepSwipes = true
            if config.scrollSwipeThreshold_inTicks > consecutiveScrollTickCounter {
                keepSwipes = false
            } else if secondsSinceLastTick > config.consecutiveScrollSwipeMaxInterval {
                keepSwipes = false
            } else {
                let tickSpeedThisSwipeSequence = Double(ticksInCurrentConsecutiveSwipeSequence) / (time - consecutiveSwipeSequenceStartTime)
                if tickSpeedThisSwipeSequence < config.consecutiveScrollSwipeMinTickSpeed {
                    keepSwipes = false
                }
            }
            if keepSwipes {
                consecutiveScrollSwipeCounter += 1
                consecutiveScrollSwipeCounter_ForFreeScrollWheel += 1
            } else {
                consecutiveScrollSwipeCounter = 0
                consecutiveScrollSwipeCounter_ForFreeScrollWheel = 0
                consecutiveSwipeSequenceStartTime = time
                ticksInCurrentConsecutiveSwipeSequence = 0
            }
            consecutiveScrollTickCounter = 0
        } else {
            consecutiveScrollTickCounter += 1
        }

        // Smoothing
        let smoothedTimeBetweenTicks: Double
        if consecutiveScrollTickCounter == 0 {
            smoothedTimeBetweenTicks = .greatestFiniteMagnitude
            tickTimeSmoother.reset()
            if config.smoothness == .high && !config.precise {
                // "HORRIBLE HACK" from Mac Mouse Fix: pre-seed the smoother so short fast swipes accelerate more slowly.
                _ = tickTimeSmoother.smooth(value: config.consecutiveScrollTickIntervalMax)
            }
        } else {
            smoothedTimeBetweenTicks = tickTimeSmoother.smooth(value: secondsSinceLastTick)
        }

        previousScrollTickTimeStamp = time

        var result = ScrollAnalysisResult(consecutiveScrollTickCounter: consecutiveScrollTickCounter,
                                          consecutiveScrollSwipeCounter: consecutiveScrollSwipeCounter_ForFreeScrollWheel,
                                          scrollDirectionDidChange: scrollDirectionDidChange,
                                          timeBetweenTicks: smoothedTimeBetweenTicks,
                                          timeBetweenTicksRaw: secondsSinceLastTick)
        if result.timeBetweenTicks > config.consecutiveScrollTickIntervalMax && result.timeBetweenTicks != .greatestFiniteMagnitude {
            Log.scroll.error("ScrollAnalyzer: smoothed tick time over max (recovering)")
            result.timeBetweenTicks = config.consecutiveScrollTickIntervalMax
        }
        return result
    }
}
