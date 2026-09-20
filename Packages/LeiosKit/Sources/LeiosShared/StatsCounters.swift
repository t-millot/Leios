// StatsCounters.swift
// Leios — the scalar tallies that make up one bucket of usage statistics.

import Foundation

/// Everything Leios counts, as plain scalars. One of these exists per hour, per day, per month and
/// once for the lifetime of the install, and merging two periods is adding them field by field.
///
/// Encoding omits every zero field. Most buckets touch a handful of these — an hour spent scrolling
/// writes four numbers, not twenty-three — and that omission is what keeps a year of history small
/// enough to leave the key names readable, so the file can still be understood by eye.
public struct StatsCounters: Codable, Equatable, Sendable {

    // MARK: Scroll input

    // Discrete wheel notches, as they arrived from the mouse. Points are the event's own
    // `scrollWheelEventPointDelta`, before any of Leios's acceleration.

    public var inTicksUp = 0
    public var inTicksDown = 0
    public var inTicksLeft = 0
    public var inTicksRight = 0
    public var inPointsUp = 0.0
    public var inPointsDown = 0.0
    public var inPointsLeft = 0.0
    public var inPointsRight = 0.0

    /// Continuous scrolling — a trackpad or a Magic Mouse. Counted apart from the wheel because the
    /// engine never touches it, so it has no output counterpart and would flatter the wheel figures.
    public var continuousEvents = 0
    public var continuousPoints = 0.0

    /// A run of ticks with no gap longer than `StatsCounters.sequenceGap`. One flick of the wheel.
    public var scrollSequences = 0

    // MARK: Scroll output

    // What the engine actually posted, after acceleration and smoothing. Larger than the input for
    // any accelerated configuration, and zero when the scroll tap is not running.

    public var outPointsUp = 0.0
    public var outPointsDown = 0.0
    public var outPointsLeft = 0.0
    public var outPointsRight = 0.0

    // MARK: Buttons

    /// Every mouse-button press, any button, any click level.
    public var clicks = 0
    /// Presses that landed at click level 2 and 3+. A triple click adds three to `clicks`, one to
    /// `doubleClicks` and one to `tripleClicks` — these count presses *at* a level, not gestures.
    public var doubleClicks = 0
    public var tripleClicks = 0
    /// Press-and-hold recognitions that resolved to a mapped action.
    public var holds = 0
    /// Actions the engine fired, of any kind.
    public var actions = 0

    // MARK: Drag gestures

    /// Drags that passed the movement threshold and became real gestures.
    public var dragStarts = 0
    /// Pointer path length travelled during those drags, in points.
    public var dragPoints = 0.0
    public var dragSeconds = 0.0

    public init() {}

    /// The gap that ends a scroll sequence — the engine's own `consecutiveScrollTickIntervalMax`,
    /// which is what `ScrollAnalyzer` uses to decide that a tick begins a new run.
    ///
    /// Not `ScrollController.sequenceGap`, which is ten times longer and measures something else:
    /// how stale the app-under-pointer lookup may get before it is redone. Using that here counted
    /// two flicks a third of a second apart as one, which is an ordinary cadence, so the figure
    /// came out visibly low.
    ///
    /// Fixed rather than read from the live `ScrollConfig`, which raises it to 200 ms under the
    /// quick-scroll modifier: a lifetime series has to keep meaning the same thing, and it would
    /// not if the definition of a flick moved when the user changed a scroll setting.
    public static let sequenceGap: TimeInterval = 0.16

    public var isZero: Bool { self == StatsCounters() }

    // MARK: Merging

    public static func += (lhs: inout StatsCounters, rhs: StatsCounters) {
        lhs.inTicksUp += rhs.inTicksUp
        lhs.inTicksDown += rhs.inTicksDown
        lhs.inTicksLeft += rhs.inTicksLeft
        lhs.inTicksRight += rhs.inTicksRight
        lhs.inPointsUp += rhs.inPointsUp
        lhs.inPointsDown += rhs.inPointsDown
        lhs.inPointsLeft += rhs.inPointsLeft
        lhs.inPointsRight += rhs.inPointsRight
        lhs.continuousEvents += rhs.continuousEvents
        lhs.continuousPoints += rhs.continuousPoints
        lhs.scrollSequences += rhs.scrollSequences
        lhs.outPointsUp += rhs.outPointsUp
        lhs.outPointsDown += rhs.outPointsDown
        lhs.outPointsLeft += rhs.outPointsLeft
        lhs.outPointsRight += rhs.outPointsRight
        lhs.clicks += rhs.clicks
        lhs.doubleClicks += rhs.doubleClicks
        lhs.tripleClicks += rhs.tripleClicks
        lhs.holds += rhs.holds
        lhs.actions += rhs.actions
        lhs.dragStarts += rhs.dragStarts
        lhs.dragPoints += rhs.dragPoints
        lhs.dragSeconds += rhs.dragSeconds
    }

    public static func + (lhs: StatsCounters, rhs: StatsCounters) -> StatsCounters {
        var result = lhs
        result += rhs
        return result
    }

    // MARK: Derived

    public var inTicks: Int { inTicksUp + inTicksDown + inTicksLeft + inTicksRight }
    public var inPoints: Double { inPointsUp + inPointsDown + inPointsLeft + inPointsRight }
    public var outPoints: Double { outPointsUp + outPointsDown + outPointsLeft + outPointsRight }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case inTicksUp, inTicksDown, inTicksLeft, inTicksRight
        case inPointsUp, inPointsDown, inPointsLeft, inPointsRight
        case continuousEvents, continuousPoints, scrollSequences
        case outPointsUp, outPointsDown, outPointsLeft, outPointsRight
        case clicks, doubleClicks, tripleClicks, holds, actions
        case dragStarts, dragPoints, dragSeconds
    }

    /// Every field is optional and defaults to zero, so a bucket written by an older or a newer
    /// Leios — one that had fewer counters, or has more — still loads. Statistics are additive:
    /// a field we do not understand is one we simply do not show.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        func dbl(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        inTicksUp = try int(.inTicksUp)
        inTicksDown = try int(.inTicksDown)
        inTicksLeft = try int(.inTicksLeft)
        inTicksRight = try int(.inTicksRight)
        inPointsUp = try dbl(.inPointsUp)
        inPointsDown = try dbl(.inPointsDown)
        inPointsLeft = try dbl(.inPointsLeft)
        inPointsRight = try dbl(.inPointsRight)
        continuousEvents = try int(.continuousEvents)
        continuousPoints = try dbl(.continuousPoints)
        scrollSequences = try int(.scrollSequences)
        outPointsUp = try dbl(.outPointsUp)
        outPointsDown = try dbl(.outPointsDown)
        outPointsLeft = try dbl(.outPointsLeft)
        outPointsRight = try dbl(.outPointsRight)
        clicks = try int(.clicks)
        doubleClicks = try int(.doubleClicks)
        tripleClicks = try int(.tripleClicks)
        holds = try int(.holds)
        actions = try int(.actions)
        dragStarts = try int(.dragStarts)
        dragPoints = try dbl(.dragPoints)
        dragSeconds = try dbl(.dragSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func int(_ value: Int, _ key: CodingKeys) throws { if value != 0 { try c.encode(value, forKey: key) } }
        func dbl(_ value: Double, _ key: CodingKeys) throws { if value != 0 { try c.encode(value, forKey: key) } }
        try int(inTicksUp, .inTicksUp)
        try int(inTicksDown, .inTicksDown)
        try int(inTicksLeft, .inTicksLeft)
        try int(inTicksRight, .inTicksRight)
        try dbl(inPointsUp, .inPointsUp)
        try dbl(inPointsDown, .inPointsDown)
        try dbl(inPointsLeft, .inPointsLeft)
        try dbl(inPointsRight, .inPointsRight)
        try int(continuousEvents, .continuousEvents)
        try dbl(continuousPoints, .continuousPoints)
        try int(scrollSequences, .scrollSequences)
        try dbl(outPointsUp, .outPointsUp)
        try dbl(outPointsDown, .outPointsDown)
        try dbl(outPointsLeft, .outPointsLeft)
        try dbl(outPointsRight, .outPointsRight)
        try int(clicks, .clicks)
        try int(doubleClicks, .doubleClicks)
        try int(tripleClicks, .tripleClicks)
        try int(holds, .holds)
        try int(actions, .actions)
        try int(dragStarts, .dragStarts)
        try dbl(dragPoints, .dragPoints)
        try dbl(dragSeconds, .dragSeconds)
    }
}

/// Which way a scroll went, in the four directions the statistics break down by.
public enum StatsScrollDirection: String, CaseIterable, Codable, Sendable {
    case up, down, left, right

    public var displayName: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

public extension StatsCounters {
    func inPoints(_ direction: StatsScrollDirection) -> Double {
        switch direction {
        case .up: return inPointsUp
        case .down: return inPointsDown
        case .left: return inPointsLeft
        case .right: return inPointsRight
        }
    }

    func outPoints(_ direction: StatsScrollDirection) -> Double {
        switch direction {
        case .up: return outPointsUp
        case .down: return outPointsDown
        case .left: return outPointsLeft
        case .right: return outPointsRight
        }
    }

    func inTicks(_ direction: StatsScrollDirection) -> Int {
        switch direction {
        case .up: return inTicksUp
        case .down: return inTicksDown
        case .left: return inTicksLeft
        case .right: return inTicksRight
        }
    }
}
