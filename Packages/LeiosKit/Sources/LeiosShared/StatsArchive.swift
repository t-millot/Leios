// StatsArchive.swift
// Leios — the three-tier usage-statistics document the helper writes and the app reads.

import Foundation

/// Per-button tallies. Kept beside the scalar totals because "which button do I actually use"
/// is the one breakdown a mouse's statistics really owes the reader.
public struct StatsButtonCounts: Codable, Equatable, Sendable {
    /// Every press of this button, at any click level.
    public var clicks = 0
    public var doubleClicks = 0
    public var tripleClicks = 0
    public var holds = 0
    public var actions = 0

    public init() {}

    public static func += (lhs: inout StatsButtonCounts, rhs: StatsButtonCounts) {
        lhs.clicks += rhs.clicks
        lhs.doubleClicks += rhs.doubleClicks
        lhs.tripleClicks += rhs.tripleClicks
        lhs.holds += rhs.holds
        lhs.actions += rhs.actions
    }

    enum CodingKeys: String, CodingKey { case clicks, doubleClicks, tripleClicks, holds, actions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clicks = try c.decodeIfPresent(Int.self, forKey: .clicks) ?? 0
        doubleClicks = try c.decodeIfPresent(Int.self, forKey: .doubleClicks) ?? 0
        tripleClicks = try c.decodeIfPresent(Int.self, forKey: .tripleClicks) ?? 0
        holds = try c.decodeIfPresent(Int.self, forKey: .holds) ?? 0
        actions = try c.decodeIfPresent(Int.self, forKey: .actions) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if clicks != 0 { try c.encode(clicks, forKey: .clicks) }
        if doubleClicks != 0 { try c.encode(doubleClicks, forKey: .doubleClicks) }
        if tripleClicks != 0 { try c.encode(tripleClicks, forKey: .tripleClicks) }
        if holds != 0 { try c.encode(holds, forKey: .holds) }
        if actions != 0 { try c.encode(actions, forKey: .actions) }
    }
}

/// Per-gesture drag tallies, keyed by `MouseDragGesture.rawValue`.
public struct StatsDragCounts: Codable, Equatable, Sendable {
    public var starts = 0
    public var points = 0.0
    public var seconds = 0.0

    public init() {}

    public static func += (lhs: inout StatsDragCounts, rhs: StatsDragCounts) {
        lhs.starts += rhs.starts
        lhs.points += rhs.points
        lhs.seconds += rhs.seconds
    }

    enum CodingKeys: String, CodingKey { case starts, points, seconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        starts = try c.decodeIfPresent(Int.self, forKey: .starts) ?? 0
        points = try c.decodeIfPresent(Double.self, forKey: .points) ?? 0
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if starts != 0 { try c.encode(starts, forKey: .starts) }
        if points != 0 { try c.encode(points, forKey: .points) }
        if seconds != 0 { try c.encode(seconds, forKey: .seconds) }
    }
}

/// Scalars plus the three breakdowns. What a day, a month and the lifetime each hold.
public struct StatsTotals: Codable, Equatable, Sendable {
    public var counters = StatsCounters()
    /// Keyed by button number as a string ("3"…"32"), so it survives JSON without a custom coder.
    public var buttons: [String: StatsButtonCounts] = [:]
    /// Keyed by `MouseDragGesture.rawValue`.
    public var drags: [String: StatsDragCounts] = [:]
    /// Keyed by `Action.statsKey` — a stable identifier, deliberately not `displayName`.
    ///
    /// Not interned into a lookup table: a day touches a handful of distinct actions, so the table
    /// would save a few kilobytes a year and cost a per-device index that every merge across Macs
    /// would have to translate. Plain keys merge by themselves.
    public var actions: [String: Int] = [:]

    public init() {}

    public var isEmpty: Bool { counters.isZero && buttons.isEmpty && drags.isEmpty && actions.isEmpty }

    public static func += (lhs: inout StatsTotals, rhs: StatsTotals) {
        lhs.counters += rhs.counters
        for (key, value) in rhs.buttons { lhs.buttons[key, default: StatsButtonCounts()] += value }
        for (key, value) in rhs.drags { lhs.drags[key, default: StatsDragCounts()] += value }
        for (key, value) in rhs.actions { lhs.actions[key, default: 0] += value }
    }

    public static func + (lhs: StatsTotals, rhs: StatsTotals) -> StatsTotals {
        var result = lhs
        result += rhs
        return result
    }

    enum CodingKeys: String, CodingKey { case counters, buttons, drags, actions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counters = try c.decodeIfPresent(StatsCounters.self, forKey: .counters) ?? StatsCounters()
        buttons = try c.decodeIfPresent([String: StatsButtonCounts].self, forKey: .buttons) ?? [:]
        drags = try c.decodeIfPresent([String: StatsDragCounts].self, forKey: .drags) ?? [:]
        actions = try c.decodeIfPresent([String: Int].self, forKey: .actions) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !counters.isZero { try c.encode(counters, forKey: .counters) }
        if !buttons.isEmpty { try c.encode(buttons, forKey: .buttons) }
        if !drags.isEmpty { try c.encode(drags, forKey: .drags) }
        if !actions.isEmpty { try c.encode(actions, forKey: .actions) }
    }
}

/// One hour, keyed by UTC epoch-hour. Scalars only: the hourly tier exists to give the week view
/// its shape, and a per-action breakdown at hour resolution would be most of the file for nothing.
public struct StatsHour: Codable, Equatable, Sendable {
    /// `Int(date.timeIntervalSince1970 / 3600)`. UTC, so it is exact; it becomes a local hour only
    /// when the app renders it through `Calendar`.
    public var hour: Int
    public var counters: StatsCounters

    public init(hour: Int, counters: StatsCounters = StatsCounters()) {
        self.hour = hour
        self.counters = counters
    }

    enum CodingKeys: String, CodingKey { case hour, counters }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 0
        counters = try c.decodeIfPresent(StatsCounters.self, forKey: .counters) ?? StatsCounters()
    }
}

/// One day or one month, keyed by the calendar date itself rather than by an offset: a day is
/// `yyyyMMdd` and a month is `yyyyMM`, both in the local calendar of the Mac that recorded them.
///
/// Dates rather than epoch offsets on purpose. A day is 23 or 25 hours twice a year, and two Macs
/// can be in different time zones; "the 20th of September" survives both, and no arithmetic here
/// ever has to know how many seconds a day had.
public struct StatsPeriod: Codable, Equatable, Sendable {
    public var key: Int
    public var totals: StatsTotals

    public init(key: Int, totals: StatsTotals = StatsTotals()) {
        self.key = key
        self.totals = totals
    }

    enum CodingKeys: String, CodingKey { case key, totals }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(Int.self, forKey: .key) ?? 0
        totals = try c.decodeIfPresent(StatsTotals.self, forKey: .totals) ?? StatsTotals()
    }
}

/// One Mac's usage statistics.
///
/// The three tiers are maintained *independently* — every batch of counts is added to the current
/// hour, the current day, the current month and the lifetime totals at the same time. Nothing is
/// ever rolled up from one tier into another, so maintenance is pruning alone and the tiers cannot
/// drift apart or double-count each other.
public struct StatsArchive: Codable, Equatable, Sendable {

    public static let schemaVersion = 1

    /// Hourly buckets are kept for this many days, then dropped. The day, month and lifetime
    /// tallies they contributed to stay.
    public static let hourlyRetentionDays = 30
    /// Daily buckets are kept for this many days. A leap year's worth, so "the last year" is whole.
    public static let dailyRetentionDays = 366

    public var version: Int
    /// Stable per-Mac identifier, so several Macs' archives can be summed without counting one twice.
    public var deviceID: String
    public var deviceName: String
    /// When counting began — the install, or the last reset. Shown as "since …".
    public var startedAt: Date

    /// Sorted ascending by `hour`.
    public var hourly: [StatsHour]
    /// Sorted ascending by `key` (`yyyyMMdd`).
    public var daily: [StatsPeriod]
    /// Sorted ascending by `key` (`yyyyMM`). Never pruned — this is what gives the lifetime view
    /// a shape once the daily buckets behind it have gone.
    public var monthly: [StatsPeriod]
    public var lifetime: StatsTotals

    public init(deviceID: String = "", deviceName: String = "", startedAt: Date = Date()) {
        version = Self.schemaVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.startedAt = startedAt
        hourly = []
        daily = []
        monthly = []
        lifetime = StatsTotals()
    }

    public var isEmpty: Bool { lifetime.isEmpty }

    // MARK: Keys

    /// UTC epoch-hour.
    public static func hourKey(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 3600).rounded(.down))
    }

    /// `yyyyMMdd` in the given calendar.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// `yyyyMM` in the given calendar.
    public static func monthKey(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 0) * 100 + (c.month ?? 0)
    }

    public static func date(fromDayKey key: Int, calendar: Calendar = .current) -> Date? {
        var c = DateComponents()
        c.year = key / 10000
        c.month = (key / 100) % 100
        c.day = key % 100
        return calendar.date(from: c)
    }

    public static func date(fromMonthKey key: Int, calendar: Calendar = .current) -> Date? {
        var c = DateComponents()
        c.year = key / 100
        c.month = key % 100
        c.day = 1
        return calendar.date(from: c)
    }

    public static func date(fromHourKey key: Int) -> Date {
        Date(timeIntervalSince1970: Double(key) * 3600)
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case version, deviceID, deviceName, startedAt, hourly, daily, monthly, lifetime
    }

    /// Tolerant in the same way `LeiosConfig.init(from:)` is, and for a stronger reason: this file
    /// is only ever counts. A section we cannot read is worth losing; the whole history is not.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.schemaVersion
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        hourly = try (c.decodeIfPresent([StatsHour].self, forKey: .hourly) ?? []).sorted { $0.hour < $1.hour }
        daily = try (c.decodeIfPresent([StatsPeriod].self, forKey: .daily) ?? []).sorted { $0.key < $1.key }
        monthly = try (c.decodeIfPresent([StatsPeriod].self, forKey: .monthly) ?? []).sorted { $0.key < $1.key }
        lifetime = try c.decodeIfPresent(StatsTotals.self, forKey: .lifetime) ?? StatsTotals()
    }
}
