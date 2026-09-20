// StatsRecording.swift
// Leios — folding a batch of counts into an archive, and keeping the archive's size bounded.

import Foundation

public extension StatsArchive {

    /// Adds one batch of counts, as collected by the engine, to every tier at once.
    ///
    /// `date` is when the batch was *flushed*, not when each event in it happened. The engine
    /// accumulates for up to a minute before handing a batch over — reading the clock per event is
    /// exactly the cost this design exists to avoid — so a batch that straddles an hour boundary
    /// lands wholly in the later hour. Under a minute of skew, twice an hour at worst.
    mutating func apply(_ batch: StatsTotals, at date: Date, calendar: Calendar = .current) {
        guard !batch.isEmpty else { return }

        // The hourly tier carries scalars only; per-action detail by the hour would be most of
        // the file and nobody reads a chart at that resolution.
        let hourIndex = Self.slot(forHour: Self.hourKey(date), in: &hourly)
        hourly[hourIndex].counters += batch.counters

        let dayIndex = Self.slot(forKey: Self.dayKey(date, calendar: calendar), in: &daily)
        daily[dayIndex].totals += batch

        let monthIndex = Self.slot(forKey: Self.monthKey(date, calendar: calendar), in: &monthly)
        monthly[monthIndex].totals += batch

        lifetime += batch
    }

    /// Drops buckets past their retention. Monthly and lifetime are kept forever, which is what
    /// leaves the lifetime view with a shape once the daily buckets behind it have gone.
    ///
    /// Idempotent, and safe at any cadence: it compares keys against `now` rather than counting
    /// how long it has been since the last call.
    mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        let oldestHour = Self.hourKey(now) - Self.hourlyRetentionDays * 24
        if let first = hourly.first, first.hour < oldestHour {
            hourly.removeAll { $0.hour < oldestHour }
        }
        if let cutoff = calendar.date(byAdding: .day, value: -Self.dailyRetentionDays, to: now) {
            let oldestDay = Self.dayKey(cutoff, calendar: calendar)
            if let first = daily.first, first.key < oldestDay {
                daily.removeAll { $0.key < oldestDay }
            }
        }
    }
}

// MARK: Sorted-array access

//
// The tiers are sorted arrays rather than dictionaries: JSON has no integer keys, and an ordered
// array keeps the file readable by eye. Every write in practice lands on the last element — the
// current hour — but a binary search costs nothing and stays right when the clock moves backwards.

extension StatsArchive {

    /// Where `key` belongs in a sorted array, and whether it is already there.
    private static func search(_ key: Int, count: Int, keyAt: (Int) -> Int) -> (index: Int, exists: Bool) {
        var low = 0
        var high = count
        while low < high {
            let mid = low + (high - low) / 2
            if keyAt(mid) < key { low = mid + 1 } else { high = mid }
        }
        return (low, low < count && keyAt(low) == key)
    }

    static func slot(forHour hour: Int, in array: inout [StatsHour]) -> Int {
        let found = search(hour, count: array.count) { array[$0].hour }
        if !found.exists { array.insert(StatsHour(hour: hour), at: found.index) }
        return found.index
    }

    static func slot(forKey key: Int, in array: inout [StatsPeriod]) -> Int {
        let found = search(key, count: array.count) { array[$0].key }
        if !found.exists { array.insert(StatsPeriod(key: key), at: found.index) }
        return found.index
    }
}
