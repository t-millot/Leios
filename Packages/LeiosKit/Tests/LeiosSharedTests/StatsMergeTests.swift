import XCTest
@testable import LeiosShared

final class StatsMergeTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let day = Date(timeIntervalSince1970: 1_789_000_000) // 2026-09-08T10:26:40Z

    private func archive(id: String, name: String, clicks: Int, action: String, at offsetHours: Int = 0,
                         startedAt: Date? = nil) -> StatsArchive {
        var archive = StatsArchive(deviceID: id, deviceName: name, startedAt: startedAt ?? day)
        var totals = StatsTotals()
        totals.counters.clicks = clicks
        totals.actions[action] = clicks
        totals.buttons["4"] = { var c = StatsButtonCounts(); c.clicks = clicks; return c }()
        archive.apply(totals, at: day.addingTimeInterval(Double(offsetHours) * 3600), calendar: utc)
        return archive
    }

    func testMergingNothingIsEmpty() {
        XCTAssertTrue(StatsMerge.merge([]).isEmpty)
        XCTAssertTrue(StatsMerge.merge([]).devices.isEmpty)
    }

    func testMergingOneArchiveIsThatArchive() {
        let one = archive(id: "a", name: "Mac", clicks: 7, action: "smartZoom")
        let merged = StatsMerge.merge([one], thisDeviceID: "a")
        XCTAssertEqual(merged.lifetime, one.lifetime)
        XCTAssertEqual(merged.daily.map(\.key), one.daily.map(\.key))
        XCTAssertEqual(merged.devices.count, 1)
        XCTAssertTrue(merged.devices[0].isThisMac)
    }

    func testOverlappingBucketsAreSummed() {
        let a = archive(id: "a", name: "Studio", clicks: 3, action: "navigateBack")
        let b = archive(id: "b", name: "Air", clicks: 4, action: "navigateBack")
        let merged = StatsMerge.merge([a, b], thisDeviceID: "a")
        XCTAssertEqual(merged.lifetime.counters.clicks, 7)
        XCTAssertEqual(merged.lifetime.actions["navigateBack"], 7)
        XCTAssertEqual(merged.lifetime.buttons["4"]?.clicks, 7)
        XCTAssertEqual(merged.hourly.count, 1)
        XCTAssertEqual(merged.hourly[0].counters.clicks, 7)
        XCTAssertEqual(merged.daily.count, 1)
    }

    func testDisjointBucketsAreUnioned() {
        let a = archive(id: "a", name: "Studio", clicks: 3, action: "smartZoom", at: 0)
        let b = archive(id: "b", name: "Air", clicks: 4, action: "smartZoom", at: 5)
        let merged = StatsMerge.merge([a, b], thisDeviceID: "a")
        XCTAssertEqual(merged.hourly.count, 2)
        XCTAssertEqual(merged.hourly.map(\.hour), merged.hourly.map(\.hour).sorted())
        XCTAssertEqual(merged.lifetime.counters.clicks, 7)
    }

    func testThreeMacsWithDifferentActions() {
        let merged = StatsMerge.merge([
            archive(id: "a", name: "Studio", clicks: 1, action: "navigateBack"),
            archive(id: "b", name: "Air", clicks: 2, action: "smartZoom", at: 1),
            archive(id: "c", name: "Mini", clicks: 3, action: "symbolicHotkey.missionControl", at: 2),
        ], thisDeviceID: "a")
        XCTAssertEqual(merged.lifetime.counters.clicks, 6)
        XCTAssertEqual(merged.lifetime.actions.count, 3)
        XCTAssertEqual(merged.devices.count, 3)
        // Ordered by how much each Mac contributed, so the busiest reads first.
        XCTAssertEqual(merged.devices.map(\.deviceName), ["Mini", "Air", "Studio"])
    }

    /// This Mac's own archive also exists as a copy in iCloud. Counting it twice would double
    /// every lifetime number the moment sync was switched on.
    func testTheSameMacIsNeverCountedTwice() {
        let local = archive(id: "a", name: "Studio", clicks: 5, action: "smartZoom")
        var stale = local
        stale.deviceName = "Studio (from iCloud)"
        let merged = StatsMerge.merge([local, stale], thisDeviceID: "a")
        XCTAssertEqual(merged.lifetime.counters.clicks, 5)
        XCTAssertEqual(merged.devices.count, 1)
        XCTAssertEqual(merged.devices[0].deviceName, "Studio")
    }

    func testStartedAtIsTheEarliestAcrossMacs() {
        let early = day.addingTimeInterval(-90000)
        let a = archive(id: "a", name: "Studio", clicks: 1, action: "smartZoom", startedAt: day)
        let b = archive(id: "b", name: "Air", clicks: 1, action: "smartZoom", startedAt: early)
        XCTAssertEqual(StatsMerge.merge([a, b], thisDeviceID: "a").startedAt, early)
    }

    func testMergingIsOrderIndependentApartFromDeduplication() {
        let a = archive(id: "a", name: "Studio", clicks: 3, action: "navigateBack", at: 0)
        let b = archive(id: "b", name: "Air", clicks: 4, action: "smartZoom", at: 2)
        let forward = StatsMerge.merge([a, b], thisDeviceID: "a")
        let backward = StatsMerge.merge([b, a], thisDeviceID: "a")
        XCTAssertEqual(forward.lifetime, backward.lifetime)
        XCTAssertEqual(forward.hourly, backward.hourly)
        XCTAssertEqual(forward.daily, backward.daily)
    }

    /// An archive written before device identifiers existed belongs to whichever Mac is reading it.
    func testArchiveWithoutADeviceIDIsTreatedAsThisMac() {
        let legacy = archive(id: "", name: "", clicks: 2, action: "smartZoom")
        let merged = StatsMerge.merge([legacy], thisDeviceID: "a")
        XCTAssertEqual(merged.devices.count, 1)
        XCTAssertTrue(merged.devices[0].isThisMac)
    }
}
