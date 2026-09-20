import XCTest
@testable import LeiosShared

final class StatsArchiveTests: XCTestCase {

    /// A fixed calendar, so a test never depends on where the machine running it happens to be.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func batch(clicks: Int = 0, ticksUp: Int = 0, action: String? = nil, button: Int? = nil) -> StatsTotals {
        var totals = StatsTotals()
        totals.counters.clicks = clicks
        totals.counters.inTicksUp = ticksUp
        if let action { totals.actions[action] = 1 }
        if let button {
            var counts = StatsButtonCounts()
            counts.clicks = clicks
            totals.buttons[String(button)] = counts
        }
        return totals
    }

    // MARK: Merging scalars

    func testAddingCountersIsFieldwise() {
        var a = StatsCounters()
        a.clicks = 3
        a.inPointsUp = 1.5
        var b = StatsCounters()
        b.clicks = 4
        b.outPointsDown = 2
        let sum = a + b
        XCTAssertEqual(sum.clicks, 7)
        XCTAssertEqual(sum.inPointsUp, 1.5)
        XCTAssertEqual(sum.outPointsDown, 2)
    }

    func testAddingIsCommutativeAndZeroIsTheIdentity() {
        var a = StatsCounters()
        a.clicks = 5
        a.dragPoints = 12.5
        var b = StatsCounters()
        b.holds = 2
        b.dragPoints = 0.25
        XCTAssertEqual(a + b, b + a)
        XCTAssertEqual(a + StatsCounters(), a)
        XCTAssertTrue(StatsCounters().isZero)
    }

    func testAddingTotalsMergesDictionaries() {
        var a = StatsTotals()
        a.actions["navigateBack"] = 2
        a.buttons["4"] = { var c = StatsButtonCounts(); c.clicks = 2; return c }()
        var b = StatsTotals()
        b.actions["navigateBack"] = 3
        b.actions["smartZoom"] = 1
        b.buttons["4"] = { var c = StatsButtonCounts(); c.clicks = 1; c.holds = 4; return c }()
        b.buttons["5"] = StatsButtonCounts()
        let sum = a + b
        XCTAssertEqual(sum.actions["navigateBack"], 5)
        XCTAssertEqual(sum.actions["smartZoom"], 1)
        XCTAssertEqual(sum.buttons["4"]?.clicks, 3)
        XCTAssertEqual(sum.buttons["4"]?.holds, 4)
        XCTAssertNotNil(sum.buttons["5"])
    }

    // MARK: Applying batches

    func testApplyHitsEveryTier() {
        var archive = StatsArchive()
        let when = date("2026-09-20T14:30:00Z")
        archive.apply(batch(clicks: 3, action: "smartZoom", button: 4), at: when, calendar: utc)

        XCTAssertEqual(archive.hourly.count, 1)
        XCTAssertEqual(archive.hourly[0].hour, StatsArchive.hourKey(when))
        XCTAssertEqual(archive.hourly[0].counters.clicks, 3)
        XCTAssertEqual(archive.daily.map(\.key), [20_260_920])
        XCTAssertEqual(archive.daily[0].totals.actions["smartZoom"], 1)
        XCTAssertEqual(archive.monthly.map(\.key), [202_609])
        XCTAssertEqual(archive.lifetime.counters.clicks, 3)
        XCTAssertEqual(archive.lifetime.buttons["4"]?.clicks, 3)
    }

    func testHourlyCarriesScalarsOnly() {
        var archive = StatsArchive()
        archive.apply(batch(clicks: 1, action: "smartZoom", button: 4), at: date("2026-09-20T14:30:00Z"), calendar: utc)
        // The hourly tier has no dictionaries at all — that is what keeps a month of them small.
        XCTAssertEqual(archive.hourly[0].counters.clicks, 1)
    }

    func testApplyingAnEmptyBatchChangesNothing() {
        var archive = StatsArchive()
        archive.apply(StatsTotals(), at: date("2026-09-20T14:30:00Z"), calendar: utc)
        XCTAssertTrue(archive.hourly.isEmpty)
        XCTAssertTrue(archive.daily.isEmpty)
        XCTAssertTrue(archive.isEmpty)
    }

    func testRepeatedBatchesAccumulateInOneBucket() {
        var archive = StatsArchive()
        for _ in 0..<5 {
            archive.apply(batch(clicks: 2), at: date("2026-09-20T14:30:00Z"), calendar: utc)
        }
        XCTAssertEqual(archive.hourly.count, 1)
        XCTAssertEqual(archive.daily.count, 1)
        XCTAssertEqual(archive.lifetime.counters.clicks, 10)
    }

    func testTiersStayIndependentlyConsistent() {
        var archive = StatsArchive()
        for hour in 0..<48 {
            let when = date("2026-09-20T00:30:00Z").addingTimeInterval(Double(hour) * 3600)
            archive.apply(batch(clicks: 1), at: when, calendar: utc)
        }
        // Nothing is ever rolled up between tiers, so each holds the same total independently.
        XCTAssertEqual(archive.hourly.reduce(0) { $0 + $1.counters.clicks }, 48)
        XCTAssertEqual(archive.daily.reduce(0) { $0 + $1.totals.counters.clicks }, 48)
        XCTAssertEqual(archive.monthly.reduce(0) { $0 + $1.totals.counters.clicks }, 48)
        XCTAssertEqual(archive.lifetime.counters.clicks, 48)
        XCTAssertEqual(archive.daily.count, 2)
    }

    func testBucketsStaySortedWhenTheClockMovesBackwards() {
        var archive = StatsArchive()
        archive.apply(batch(clicks: 1), at: date("2026-09-20T14:30:00Z"), calendar: utc)
        archive.apply(batch(clicks: 1), at: date("2026-09-19T09:00:00Z"), calendar: utc)
        archive.apply(batch(clicks: 1), at: date("2026-09-20T02:00:00Z"), calendar: utc)
        XCTAssertEqual(archive.hourly.map(\.hour), archive.hourly.map(\.hour).sorted())
        XCTAssertEqual(archive.daily.map(\.key), [20_260_919, 20_260_920])
    }

    // MARK: Pruning

    func testPruneDropsHourlyPastRetentionAndKeepsTheRest() {
        var archive = StatsArchive()
        let now = date("2026-09-20T12:00:00Z")
        let old = now.addingTimeInterval(-Double(StatsArchive.hourlyRetentionDays * 24 + 1) * 3600)
        archive.apply(batch(clicks: 1), at: old, calendar: utc)
        archive.apply(batch(clicks: 1), at: now, calendar: utc)
        XCTAssertEqual(archive.hourly.count, 2)

        archive.prune(now: now, calendar: utc)
        XCTAssertEqual(archive.hourly.count, 1)
        // The day, month and lifetime tallies that hour fed are untouched.
        XCTAssertEqual(archive.daily.count, 2)
        XCTAssertEqual(archive.lifetime.counters.clicks, 2)
    }

    func testPruneKeepsTheHourExactlyOnTheBoundary() {
        var archive = StatsArchive()
        let now = date("2026-09-20T12:00:00Z")
        let boundary = now.addingTimeInterval(-Double(StatsArchive.hourlyRetentionDays * 24) * 3600)
        archive.apply(batch(clicks: 1), at: boundary, calendar: utc)
        archive.prune(now: now, calendar: utc)
        XCTAssertEqual(archive.hourly.count, 1)
    }

    func testPruneDropsDailyPastRetentionButNeverMonthly() {
        var archive = StatsArchive()
        let now = date("2026-09-20T12:00:00Z")
        let old = utc.date(byAdding: .day, value: -(StatsArchive.dailyRetentionDays + 1), to: now)!
        archive.apply(batch(clicks: 1), at: old, calendar: utc)
        archive.apply(batch(clicks: 1), at: now, calendar: utc)

        archive.prune(now: now, calendar: utc)
        XCTAssertEqual(archive.daily.count, 1)
        XCTAssertEqual(archive.monthly.count, 2)
        XCTAssertEqual(archive.lifetime.counters.clicks, 2)
    }

    func testPruneIsIdempotent() {
        var archive = StatsArchive()
        let now = date("2026-09-20T12:00:00Z")
        for day in 0...(StatsArchive.dailyRetentionDays + 40) {
            archive.apply(batch(clicks: 1), at: utc.date(byAdding: .day, value: -day, to: now)!, calendar: utc)
        }
        archive.prune(now: now, calendar: utc)
        let once = archive
        archive.prune(now: now, calendar: utc)
        XCTAssertEqual(archive, once)
    }

    // MARK: Keys

    func testDayKeyIsTheCalendarDateNotAnOffset() {
        XCTAssertEqual(StatsArchive.dayKey(date("2026-01-05T23:59:59Z"), calendar: utc), 20_260_105)
        XCTAssertEqual(StatsArchive.monthKey(date("2026-01-05T23:59:59Z"), calendar: utc), 202_601)
    }

    func testDayKeysRoundTripThroughDates() {
        let original = date("2026-09-20T14:30:00Z")
        let key = StatsArchive.dayKey(original, calendar: utc)
        let back = StatsArchive.date(fromDayKey: key, calendar: utc)
        XCTAssertEqual(StatsArchive.dayKey(back!, calendar: utc), key)
    }

    /// A day is 23 hours when DST starts. Keying by the calendar date rather than by a count of
    /// 86400-second blocks is what makes that a non-event.
    func testDaylightSavingDayIsStillOneDay() {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        var archive = StatsArchive()
        // 29 March 2026: clocks go forward at 02:00 local.
        for hour in stride(from: 0, to: 24, by: 3) {
            let when = date("2026-03-29T00:30:00Z").addingTimeInterval(Double(hour) * 3600)
            archive.apply(batch(clicks: 1), at: when, calendar: paris)
        }
        XCTAssertEqual(archive.daily.filter { $0.key == 20_260_329 }.count, 1)
        XCTAssertEqual(archive.lifetime.counters.clicks, 8)
    }

    // MARK: Codable

    func testRoundTrip() throws {
        var archive = StatsArchive(deviceID: "abc", deviceName: "Mac", startedAt: date("2026-01-01T00:00:00Z"))
        archive.apply(batch(clicks: 4, ticksUp: 9, action: "navigateBack", button: 4),
                      at: date("2026-09-20T14:30:00Z"), calendar: utc)
        let data = try StatsFile.encode(archive)
        XCTAssertEqual(try StatsFile.decode(data), archive)
    }

    func testMissingSectionsDecodeToDefaults() throws {
        let data = Data(#"{"version":1}"#.utf8)
        let archive = try StatsFile.decode(data)
        XCTAssertTrue(archive.hourly.isEmpty)
        XCTAssertTrue(archive.daily.isEmpty)
        XCTAssertTrue(archive.lifetime.isEmpty)
        XCTAssertEqual(archive.deviceID, "")
    }

    /// An archive from a newer Leios — one with counters this build has never heard of — has to
    /// load. Statistics are additive: a field we do not understand is one we simply do not show.
    func testUnknownFieldsDoNotThrow() throws {
        let json = """
        {"version":99,"deviceID":"x","deviceName":"Future","startedAt":"2026-01-01T00:00:00Z",
         "lifetime":{"counters":{"clicks":5,"telepathyEvents":3},"newSection":{"a":1}},
         "daily":[{"key":20260920,"totals":{"counters":{"clicks":5}}}]}
        """
        let archive = try StatsFile.decode(Data(json.utf8))
        XCTAssertEqual(archive.lifetime.counters.clicks, 5)
        XCTAssertEqual(archive.daily.count, 1)
    }

    func testEncodingOmitsZeroes() throws {
        var archive = StatsArchive(deviceID: "abc", deviceName: "Mac")
        var totals = StatsTotals()
        totals.counters.clicks = 1
        archive.apply(totals, at: date("2026-09-20T14:30:00Z"), calendar: utc)
        let text = try XCTUnwrap(String(bytes: StatsFile.encode(archive), encoding: .utf8))
        XCTAssertTrue(text.contains("\"clicks\":1"))
        XCTAssertFalse(text.contains("inTicksUp"))
        XCTAssertFalse(text.contains("dragSeconds"))
    }

    func testBucketsAreLoadedInOrderEvenIfTheFileIsNot() throws {
        let json = """
        {"hourly":[{"hour":500000,"counters":{"clicks":1}},{"hour":400000,"counters":{"clicks":1}}],
         "daily":[{"key":20260920,"totals":{}},{"key":20260101,"totals":{}}]}
        """
        let archive = try StatsFile.decode(Data(json.utf8))
        XCTAssertEqual(archive.hourly.map(\.hour), [400_000, 500_000])
        XCTAssertEqual(archive.daily.map(\.key), [20_260_101, 20_260_920])
    }

    /// The regression test for schema bloat. A year of steady use has to stay small enough that
    /// nobody has to think about it — on disk, and as a CloudKit payload.
    func testAYearOfUseStaysSmall() throws {
        var archive = StatsArchive(deviceID: UUID().uuidString, deviceName: "MacBook Pro")
        let now = date("2026-09-20T12:00:00Z")
        var totals = StatsTotals()
        totals.counters.inTicksDown = 120
        totals.counters.inPointsDown = 1200
        totals.counters.outPointsDown = 9600.5
        totals.counters.clicks = 40
        totals.counters.scrollSequences = 18
        totals.buttons["4"] = { var c = StatsButtonCounts(); c.clicks = 6; c.actions = 6; return c }()
        totals.buttons["5"] = { var c = StatsButtonCounts(); c.clicks = 4; c.actions = 4; return c }()
        totals.actions["navigateBack"] = 6
        totals.actions["navigateForward"] = 4
        totals.drags["twoFingerSwipe"] = { var d = StatsDragCounts(); d.starts = 3; d.points = 900; return d }()

        // A year of days, and thirty days of ten flushes an hour across a ten-hour working day.
        for day in 0..<366 {
            archive.apply(totals, at: utc.date(byAdding: .day, value: -day, to: now)!, calendar: utc)
        }
        for hour in 0..<(30 * 10) {
            archive.apply(totals, at: now.addingTimeInterval(-Double(hour) * 3600), calendar: utc)
        }
        archive.prune(now: now, calendar: utc)

        let size = try StatsFile.encode(archive).count
        XCTAssertLessThan(size, 400_000, "statistics.json grew to \(size) bytes for a year of use")
    }

    // MARK: Action keys

    /// These strings are written to disk and travel between Macs, so they are API. If this test
    /// fails because a key changed, the lifetime series behind that key has just been split in two.
    func testStatsKeysAreStable() {
        XCTAssertEqual(Action.navigateBack.statsKey, "navigateBack")
        XCTAssertEqual(Action.navigateForward.statsKey, "navigateForward")
        XCTAssertEqual(Action.smartZoom.statsKey, "smartZoom")
        XCTAssertEqual(Action.middleClick.statsKey, "middleClick")
        XCTAssertEqual(Action.symbolicHotkey(.missionControl).statsKey, "symbolicHotkey.missionControl")
        XCTAssertEqual(Action.symbolicHotkey(.switchToDesktop3).statsKey, "symbolicHotkey.switchToDesktop3")
        XCTAssertEqual(Action.mouseButtonClicks(button: 4, count: 2).statsKey, "mouseButtonClicks.4x2")
        XCTAssertEqual(Action.keyboardShortcut(keyCode: 12, modifierFlags: 0).statsKey, "keyboardShortcut")
        XCTAssertEqual(Action.systemDefinedEvent(type: .volumeUp, modifierFlags: 0).statsKey,
                       "systemDefinedEvent.volumeUp")
    }

    func testEveryUIChoiceHasADistinctKeyThatResolvesToItsName() {
        var keys = Set<String>()
        for action in Action.uiChoices {
            let key = action.statsKey
            XCTAssertTrue(keys.insert(key).inserted, "duplicate stats key \(key)")
            XCTAssertEqual(Action.displayName(forStatsKey: key), action.displayName)
        }
    }

    func testKeyboardShortcutsShareOneKey() {
        XCTAssertEqual(Action.keyboardShortcut(keyCode: 1, modifierFlags: 0).statsKey,
                       Action.keyboardShortcut(keyCode: 99, modifierFlags: 256).statsKey)
        XCTAssertEqual(Action.displayName(forStatsKey: "keyboardShortcut"), "Keyboard Shortcut")
    }

    /// A key from a Leios newer than this one, arriving over iCloud, renders as itself rather
    /// than disappearing from the chart.
    func testUnknownKeyFallsBackToItself() {
        XCTAssertEqual(Action.displayName(forStatsKey: "somethingNew"), "somethingNew")
    }

    func testMouseButtonClickKeysAreParsedBack() {
        XCTAssertEqual(Action.displayName(forStatsKey: "mouseButtonClicks.4x1"), "Mouse Button 4")
        XCTAssertEqual(Action.displayName(forStatsKey: "mouseButtonClicks.5x3"), "Mouse Button 5 ×3")
    }
}
