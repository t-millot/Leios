// StatsMerge.swift
// Leios — summing several Macs' archives into one set of series. A pure function, like SyncReconciler.

import Foundation

/// One Mac's share of the merged totals, for the "where did this come from" breakdown.
public struct StatsDeviceShare: Equatable, Sendable, Identifiable {
    public var id: String { deviceID }
    public let deviceID: String
    public let deviceName: String
    public let lifetime: StatsTotals
    /// True for the archive this Mac wrote itself.
    public let isThisMac: Bool
}

/// What the Statistics pane draws: the union of every Mac's history, plus who contributed what.
public struct MergedStats: Equatable, Sendable {
    public var hourly: [StatsHour]
    public var daily: [StatsPeriod]
    public var monthly: [StatsPeriod]
    public var lifetime: StatsTotals
    public var devices: [StatsDeviceShare]
    /// The earliest start date across the Macs — how far back "lifetime" reaches.
    public var startedAt: Date

    public static let empty = MergedStats(hourly: [], daily: [], monthly: [], lifetime: StatsTotals(),
                                          devices: [], startedAt: Date())

    public var isEmpty: Bool { lifetime.isEmpty }
}

public enum StatsMerge {

    /// Sums archives bucket by bucket.
    ///
    /// Counts are additive and each Mac owns its own archive, so there is no conflict to resolve
    /// here and no last-writer-wins — merging is addition. The only rule is that a Mac must not be
    /// counted twice: archives are deduplicated by `deviceID`, keeping the first of any repeat, so
    /// the caller passes this Mac's own archive **first** and its copy in iCloud never shadows it.
    public static func merge(_ archives: [StatsArchive], thisDeviceID: String = "") -> MergedStats {
        var seen = Set<String>()
        let unique = archives.filter { archive in
            // An archive with no device identifier predates the identifier, so it is this Mac's.
            let id = archive.deviceID.isEmpty ? thisDeviceID : archive.deviceID
            return seen.insert(id).inserted
        }
        guard !unique.isEmpty else { return .empty }

        var hourly: [Int: StatsCounters] = [:]
        var daily: [Int: StatsTotals] = [:]
        var monthly: [Int: StatsTotals] = [:]
        var lifetime = StatsTotals()
        var devices: [StatsDeviceShare] = []
        var startedAt = Date.distantFuture

        for archive in unique {
            for bucket in archive.hourly { hourly[bucket.hour, default: StatsCounters()] += bucket.counters }
            for bucket in archive.daily { daily[bucket.key, default: StatsTotals()] += bucket.totals }
            for bucket in archive.monthly { monthly[bucket.key, default: StatsTotals()] += bucket.totals }
            lifetime += archive.lifetime
            startedAt = min(startedAt, archive.startedAt)
            let id = archive.deviceID.isEmpty ? thisDeviceID : archive.deviceID
            devices.append(StatsDeviceShare(deviceID: id,
                                            deviceName: archive.deviceName,
                                            lifetime: archive.lifetime,
                                            isThisMac: id == thisDeviceID))
        }

        return MergedStats(hourly: hourly.map { StatsHour(hour: $0.key, counters: $0.value) }.sorted { $0.hour < $1.hour },
                           daily: daily.map { StatsPeriod(key: $0.key, totals: $0.value) }.sorted { $0.key < $1.key },
                           monthly: monthly.map { StatsPeriod(key: $0.key, totals: $0.value) }.sorted { $0.key < $1.key },
                           lifetime: lifetime,
                           devices: devices.sorted { $0.lifetime.counters.clicks > $1.lifetime.counters.clicks },
                           startedAt: startedAt == .distantFuture ? Date() : startedAt)
    }
}
