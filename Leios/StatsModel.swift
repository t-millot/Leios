// StatsModel.swift
// Leios — reads the usage statistics the helper writes and shapes them for the charts.

import Foundation
import AppKit
import Observation
import os
import LeiosShared

/// The span the Statistics pane is showing.
enum StatsRange: String, CaseIterable, Identifiable, Sendable {
    case week, month, year, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .all: return "All Time"
        }
    }

    /// How many buckets back the chart reaches, and of what kind.
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .year, .all: return nil
        }
    }

    var isMonthly: Bool { self == .year || self == .all }

    /// Only the ranges the hourly tier actually covers get a time-of-day chart; it is kept for
    /// thirty days, so a year of it does not exist to draw.
    var hasTimeOfDay: Bool { self == .week || self == .month }
}

/// What the main chart is plotting. One measure per chart and one axis — two of these never
/// share a plot, because their units do not.
enum StatsMetric: String, CaseIterable, Identifiable, Sendable {
    case distance, ticks, clicks, drags, actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distance: return "Distance Scrolled"
        case .ticks: return "Scroll Ticks"
        case .clicks: return "Clicks"
        case .drags: return "Drag Gestures"
        case .actions: return "Actions"
        }
    }

    /// `distance` is the one metric drawn as two series: the points the wheel asked for and the
    /// points Leios delivered. Same unit, so they belong on one axis.
    var hasInputAndOutput: Bool { self == .distance }

    func value(_ counters: StatsCounters) -> Double {
        switch self {
        case .distance: return counters.outPoints
        case .ticks: return Double(counters.inTicks)
        case .clicks: return Double(counters.clicks)
        case .drags: return Double(counters.dragStarts)
        case .actions: return Double(counters.actions)
        }
    }

    func secondaryValue(_ counters: StatsCounters) -> Double {
        self == .distance ? counters.inPoints : 0
    }
}

/// One bar of the main chart. Carries the whole bucket rather than one number, so switching the
/// charted metric is a redraw and not a rebuild.
struct StatsPoint: Identifiable, Equatable {
    let id: Int
    let date: Date
    let counters: StatsCounters
}

struct StatsButtonRow: Identifiable, Equatable {
    let id: Int
    var button: Int { id }
    let counts: StatsButtonCounts
    var name: String { "Button \(button)" }
}

struct StatsActionRow: Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
}

struct StatsDirectionRow: Identifiable, Equatable {
    var id: String { direction.rawValue }
    let direction: StatsScrollDirection
    let points: Double
    let ticks: Int
}

@MainActor
@Observable
final class StatsModel {

    /// Set by the view. Rebuilds the series, which is why the series are stored rather than
    /// computed: recomputing a year of buckets on every SwiftUI body invalidation is real jank.
    var range: StatsRange = .week {
        didSet { if range != oldValue { rebuild() } }
    }

    private(set) var merged: MergedStats = .empty
    private(set) var hasLoaded = false
    private(set) var isBusy = false

    /// The main chart's buckets, oldest first.
    private(set) var series: [StatsPoint] = []
    /// Everything in the selected range, added up. What the stat tiles show.
    private(set) var summary: StatsTotals = .init()
    private(set) var buttonRows: [StatsButtonRow] = []
    private(set) var actionRows: [StatsActionRow] = []
    private(set) var directionRows: [StatsDirectionRow] = []
    /// 24 bars, midnight to midnight, in local time.
    private(set) var timeOfDay: [StatsPoint] = []

    private let log = Logger(subsystem: "com.tmillot.Leios", category: "app")
    private var calendar = Calendar.current

    // MARK: Loading

    /// Asks the helper to write out what it has counted, then reads the file.
    ///
    /// The flush is best-effort: when the helper is not running there is nothing in flight, and
    /// whatever is on disk is the last thing it wrote. Decoding happens off the main actor —
    /// a year of buckets is not a lot, but it is not nothing either.
    func refresh(using app: AppModel) async {
        isBusy = true
        defer { isBusy = false }
        await app.flushStatistics()
        await load(using: app)
    }

    /// Reads the file, and — when iCloud carries the statistics — the other Macs' copies too.
    /// Passing no `app` reads this Mac alone, which is what the pane does on first appearance so
    /// something is on screen before any round trip.
    func load(using app: AppModel? = nil) async {
        let loaded = await Task.detached(priority: .userInitiated) { () -> StatsArchive? in
            do {
                return try StatsFile.load()
            } catch {
                return nil
            }
        }.value

        guard let loaded else {
            adopt(.empty)
            return
        }
        // This Mac first, so its own copy in iCloud — which is a snapshot of this same archive,
        // up to an upload interval old — is deduplicated away rather than added on top of it.
        let peers = await app?.syncStatistics(local: loaded) ?? []
        adopt(StatsMerge.merge([loaded] + peers, thisDeviceID: loaded.deviceID))
    }

    /// Takes an already-merged set of statistics and reshapes the charts around it. The seam
    /// between reading and drawing: everything past this point is pure, which is what lets the
    /// app-hosted tests exercise the shaping without a file or an iCloud account.
    func adopt(_ stats: MergedStats) {
        calendar = Calendar.current
        hasLoaded = true
        merged = stats
        rebuild()
    }

    // MARK: Shaping

    private func rebuild() {
        let buckets = bucketsInRange()
        series = buckets
        summary = buckets.isEmpty ? StatsTotals() : totalsInRange()
        buttonRows = summary.buttons
            .compactMap { key, counts in Int(key).map { StatsButtonRow(id: $0, counts: counts) } }
            .sorted { $0.counts.clicks > $1.counts.clicks }
        actionRows = summary.actions
            .map { StatsActionRow(id: $0.key, name: Action.displayName(forStatsKey: $0.key), count: $0.value) }
            .sorted { $0.count > $1.count }
        directionRows = StatsScrollDirection.allCases.map {
            StatsDirectionRow(direction: $0,
                              points: summary.counters.outPoints($0),
                              ticks: summary.counters.inTicks($0))
        }
        timeOfDay = range.hasTimeOfDay ? hourOfDayProfile() : []
    }

    /// The buckets the chart draws: days for a week or a month, months for a year or for all time.
    private func bucketsInRange() -> [StatsPoint] {
        if range.isMonthly {
            let cutoff = range == .year ? StatsArchive.monthKey(calendar.date(byAdding: .month, value: -11, to: Date()) ?? Date(), calendar: calendar) : Int.min
            return merged.monthly
                .filter { $0.key >= cutoff }
                .compactMap { period in
                    StatsArchive.date(fromMonthKey: period.key, calendar: calendar).map {
                        StatsPoint(id: period.key, date: $0, counters: period.totals.counters)
                    }
                }
        }
        guard let days = range.days,
              let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))
        else { return [] }
        let cutoff = StatsArchive.dayKey(start, calendar: calendar)
        let recorded = Dictionary(uniqueKeysWithValues: merged.daily.filter { $0.key >= cutoff }.map { ($0.key, $0.totals.counters) })
        // Every day in the range gets a bar, including the ones with nothing in them: a week with
        // two gaps should read as a week with two gaps, not as a five-day week.
        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = StatsArchive.dayKey(date, calendar: calendar)
            return StatsPoint(id: key, date: date, counters: recorded[key] ?? StatsCounters())
        }
    }

    /// The breakdowns for the range. Taken from the day and month tiers, which carry them; the
    /// hourly tier holds scalars only.
    private func totalsInRange() -> StatsTotals {
        if range == .all { return merged.lifetime }
        var totals = StatsTotals()
        if range.isMonthly {
            let cutoff = StatsArchive.monthKey(calendar.date(byAdding: .month, value: -11, to: Date()) ?? Date(), calendar: calendar)
            for period in merged.monthly where period.key >= cutoff { totals += period.totals }
        } else if let days = range.days,
                  let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date())) {
            let cutoff = StatsArchive.dayKey(start, calendar: calendar)
            for period in merged.daily where period.key >= cutoff { totals += period.totals }
        }
        return totals
    }

    /// "When do you use your mouse" — the hourly tier folded onto a single 24-hour clock. The
    /// only thing that tier is for, and the reason it is kept at all.
    private func hourOfDayProfile() -> [StatsPoint] {
        guard let days = range.days,
              let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))
        else { return [] }
        var byHour = [StatsCounters](repeating: StatsCounters(), count: 24)
        for bucket in merged.hourly {
            let date = StatsArchive.date(fromHourKey: bucket.hour)
            guard date >= start else { continue }
            byHour[calendar.component(.hour, from: date)] += bucket.counters
        }
        let midnight = calendar.startOfDay(for: Date())
        return (0..<24).compactMap { hour in
            calendar.date(byAdding: .hour, value: hour, to: midnight).map {
                StatsPoint(id: hour, date: $0, counters: byHour[hour])
            }
        }
    }
}

// MARK: Physical distance

/// Turns scroll points into a real length.
///
/// The conversion is the main display's own pixel pitch: its size in millimetres over its size in
/// points. Points rather than pixels on purpose — that way the figure means the same thing on a
/// Retina display as on one that is not. It is an approximation and is labelled as one: a second
/// display of a different density, or a display swapped since, is not accounted for.
enum ScrollDistance {

    static var metersPerPoint: Double {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        else { return fallbackMetersPerPoint }
        let millimetres = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        let points = screen.frame.height
        guard millimetres.height > 0, points > 0 else { return fallbackMetersPerPoint }
        return millimetres.height / points / 1000
    }

    /// Roughly a 110 ppi display, which is what a point is nominally defined against. Used only
    /// when the display will not say how big it is — a projector, or a virtual screen.
    private static let fallbackMetersPerPoint = 0.0254 / 110

    private static var zero: String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: 0, unit: UnitLength.meters))
    }

    static func measurement(points: Double) -> Measurement<UnitLength> {
        Measurement(value: points * metersPerPoint, unit: UnitLength.meters)
    }

    /// "1.4 km", "230 m", "48 cm" — whichever unit keeps the number readable.
    static func format(points: Double) -> String {
        // Natural scale reaches for millimetres at zero, and "0 mm" reads as a measurement
        // somebody took rather than as nothing having happened.
        guard points != 0 else { return zero }
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = points * metersPerPoint >= 100 ? 0 : 1
        return formatter.string(from: measurement(points: points))
    }

    /// An axis label. Every tick on one axis gets the same unit — chosen from the axis's peak —
    /// because a scale that reads 0 mm, 11 m, 23 m is not a scale anyone can read down.
    static func axisLabel(points: Double, peak: Double) -> String {
        guard points != 0 else { return "0" }
        let unit = axisUnit(peak: peak)
        let value = measurement(points: points).converted(to: unit)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = value.value >= 100 ? 0 : 1
        return formatter.string(from: value)
    }

    private static func axisUnit(peak: Double) -> UnitLength {
        let metres = peak * metersPerPoint
        if metres >= 1000 { return .kilometers }
        if metres >= 1 { return .meters }
        return .centimeters
    }
}
