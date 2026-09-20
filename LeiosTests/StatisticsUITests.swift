import XCTest
@testable import Leios
@testable import LeiosShared

/// App-target coverage for what the package tests structurally cannot reach: the sidebar row and
/// the shaping `StatsModel` does between the archive on disk and the marks on the chart.
final class StatisticsUITests: XCTestCase {

    // MARK: Sidebar

    func testStatisticsRowHasATitleAndASymbol() {
        XCTAssertEqual(SidebarItem.statistics.title, "Statistics")
        XCTAssertFalse(SidebarItem.statistics.symbol.isEmpty)
    }

    func testEveryFixedRowIsDistinct() {
        let rows: [SidebarItem] = [.scrolling, .apps, .buttons, .devices, .statistics, .settings]
        XCTAssertEqual(Set(rows.map(\.title)).count, rows.count)
        XCTAssertEqual(Set(rows.map(\.symbol)).count, rows.count)
    }

    // MARK: Ranges and metrics

    func testEveryRangeAndMetricIsLabelled() {
        for range in StatsRange.allCases {
            XCTAssertFalse(range.title.isEmpty, "\(range) has no title")
        }
        for metric in StatsMetric.allCases {
            XCTAssertFalse(metric.title.isEmpty, "\(metric) has no title")
        }
        XCTAssertEqual(Set(StatsRange.allCases.map(\.title)).count, StatsRange.allCases.count)
        XCTAssertEqual(Set(StatsMetric.allCases.map(\.title)).count, StatsMetric.allCases.count)
    }

    /// Only distance has a second series, and only distance is drawn in metres. If another metric
    /// ever claims one, it would share an axis with a measure in different units.
    func testOnlyDistanceHasTwoSeries() {
        for metric in StatsMetric.allCases {
            XCTAssertEqual(metric.hasInputAndOutput, metric == .distance, "\(metric)")
        }
    }

    func testMetricsReadTheCountersTheyName() {
        var counters = StatsCounters()
        counters.outPointsDown = 500
        counters.inPointsDown = 60
        counters.inTicksDown = 6
        counters.clicks = 12
        counters.dragStarts = 3
        counters.actions = 9
        XCTAssertEqual(StatsMetric.distance.value(counters), 500)
        XCTAssertEqual(StatsMetric.distance.secondaryValue(counters), 60)
        XCTAssertEqual(StatsMetric.ticks.value(counters), 6)
        XCTAssertEqual(StatsMetric.clicks.value(counters), 12)
        XCTAssertEqual(StatsMetric.drags.value(counters), 3)
        XCTAssertEqual(StatsMetric.actions.value(counters), 9)
        XCTAssertEqual(StatsMetric.clicks.secondaryValue(counters), 0)
    }

    /// Hourly buckets are kept for thirty days, so the ranges beyond that have no time-of-day
    /// chart to draw.
    func testOnlyTheShortRangesShowTimeOfDay() {
        XCTAssertTrue(StatsRange.week.hasTimeOfDay)
        XCTAssertTrue(StatsRange.month.hasTimeOfDay)
        XCTAssertFalse(StatsRange.year.hasTimeOfDay)
        XCTAssertFalse(StatsRange.all.hasTimeOfDay)
        XCTAssertLessThanOrEqual(StatsRange.month.days ?? .max, StatsArchive.hourlyRetentionDays)
    }

    // MARK: Shaping

    @MainActor
    private func model(from archive: StatsArchive, range: StatsRange) async -> StatsModel {
        let model = StatsModel()
        model.range = range
        model.adopt(StatsMerge.merge([archive], thisDeviceID: archive.deviceID))
        return model
    }

    private func archive(daysBack: [Int], clicks: Int = 10) -> StatsArchive {
        var archive = StatsArchive(deviceID: "test", deviceName: "Test Mac")
        var totals = StatsTotals()
        totals.counters.clicks = clicks
        totals.counters.outPointsDown = 1000
        totals.counters.inPointsDown = 120
        totals.counters.inTicksDown = 12
        totals.buttons["4"] = { var c = StatsButtonCounts(); c.clicks = clicks; c.actions = clicks; return c }()
        totals.actions["navigateBack"] = clicks
        for back in daysBack {
            let when = Calendar.current.date(byAdding: .day, value: -back, to: Date())!
            archive.apply(totals, at: when)
        }
        return archive
    }

    /// A week with gaps must read as a week with gaps. Dropping the empty days would silently
    /// redraw five days of use as a solid five-day week.
    @MainActor
    func testAWeekAlwaysHasSevenBars() async {
        let model = await model(from: archive(daysBack: [0, 2, 5]), range: .week)
        XCTAssertEqual(model.series.count, 7)
        XCTAssertEqual(model.series.filter { $0.counters.clicks > 0 }.count, 3)
        XCTAssertEqual(model.series.map(\.date), model.series.map(\.date).sorted())
    }

    @MainActor
    func testAMonthHasThirtyBars() async {
        let model = await model(from: archive(daysBack: [0, 10, 29]), range: .month)
        XCTAssertEqual(model.series.count, 30)
    }

    @MainActor
    func testTheRangeSumIsWhatTheTilesShow() async {
        let model = await model(from: archive(daysBack: [0, 1, 2], clicks: 10), range: .week)
        XCTAssertEqual(model.summary.counters.clicks, 30)
        XCTAssertEqual(model.summary.buttons["4"]?.clicks, 30)
        XCTAssertEqual(model.summary.actions["navigateBack"], 30)
    }

    /// A day outside the selected range must not reach the tiles, or "last 7 days" means nothing.
    @MainActor
    func testDaysOutsideTheRangeAreExcluded() async {
        let model = await model(from: archive(daysBack: [0, 40]), range: .week)
        XCTAssertEqual(model.summary.counters.clicks, 10)
    }

    @MainActor
    func testAllTimeUsesTheLifetimeTotals() async {
        let archive = archive(daysBack: [0, 40, 200])
        let model = await model(from: archive, range: .all)
        XCTAssertEqual(model.summary.counters.clicks, archive.lifetime.counters.clicks)
    }

    @MainActor
    func testBreakdownsAreSortedHeaviestFirst() async {
        var archive = StatsArchive(deviceID: "test", deviceName: "Test Mac")
        var totals = StatsTotals()
        totals.buttons["4"] = { var c = StatsButtonCounts(); c.clicks = 3; return c }()
        totals.buttons["1"] = { var c = StatsButtonCounts(); c.clicks = 90; return c }()
        totals.buttons["5"] = { var c = StatsButtonCounts(); c.clicks = 12; return c }()
        totals.actions["smartZoom"] = 2
        totals.actions["navigateBack"] = 40
        totals.counters.clicks = 105
        archive.apply(totals, at: Date())

        let model = await model(from: archive, range: .week)
        XCTAssertEqual(model.buttonRows.map(\.button), [1, 5, 4])
        XCTAssertEqual(model.actionRows.map(\.name), ["Back", "Smart Zoom"])
    }

    @MainActor
    func testDirectionRowsAlwaysCoverAllFour() async {
        let model = await model(from: archive(daysBack: [0]), range: .week)
        XCTAssertEqual(model.directionRows.map(\.direction), StatsScrollDirection.allCases)
        XCTAssertEqual(model.directionRows.first { $0.direction == .down }?.points, 1000)
        XCTAssertEqual(model.directionRows.first { $0.direction == .up }?.points, 0)
    }

    @MainActor
    func testTimeOfDayIsTwentyFourBarsOrNothing() async {
        let week = await model(from: archive(daysBack: [0]), range: .week)
        XCTAssertEqual(week.timeOfDay.count, 24)
        let all = await model(from: archive(daysBack: [0]), range: .all)
        XCTAssertTrue(all.timeOfDay.isEmpty)
    }

    @MainActor
    func testAnEmptyArchiveShapesToNothingRatherThanCrashing() async {
        let model = await model(from: StatsArchive(deviceID: "test"), range: .week)
        XCTAssertTrue(model.merged.isEmpty)
        XCTAssertTrue(model.buttonRows.isEmpty)
        XCTAssertTrue(model.actionRows.isEmpty)
        XCTAssertEqual(model.summary.counters.clicks, 0)
    }

    // MARK: Distance

    func testDistanceGrowsWithPointsAndZeroIsZero() {
        XCTAssertEqual(ScrollDistance.measurement(points: 0).value, 0)
        // Natural scale reaches for millimetres at zero, which reads as a measurement rather
        // than as nothing having happened.
        XCTAssertFalse(ScrollDistance.format(points: 0).contains("mm"), ScrollDistance.format(points: 0))
        XCTAssertGreaterThan(ScrollDistance.measurement(points: 10000).value,
                             ScrollDistance.measurement(points: 1000).value)
        XCTAssertFalse(ScrollDistance.format(points: 500_000).isEmpty)
    }

    /// A scale reading "0 mm, 11 m, 23 m" is not a scale anyone can read down, so every tick on
    /// one axis takes its unit from that axis's peak — and zero is just zero.
    func testAxisLabelsShareOneUnit() {
        let peak = 4_000_000.0
        XCTAssertEqual(ScrollDistance.axisLabel(points: 0, peak: peak), "0")
        let low = ScrollDistance.axisLabel(points: peak / 4, peak: peak)
        let high = ScrollDistance.axisLabel(points: peak, peak: peak)
        let unit = { (label: String) in label.components(separatedBy: " ").last ?? "" }
        XCTAssertEqual(unit(low), unit(high), "\(low) and \(high) should share a unit")
    }
}
