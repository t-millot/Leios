import XCTest
@testable import LeiosEngine
@testable import LeiosShared

/// The plumbing between the engine thread and the disk: drain, fold, prune, write. Pointed at a
/// temporary directory, so it exercises the real path without touching the archive of whoever is
/// running the tests.
final class StatsFlusherTests: XCTestCase {

    private var thread: EngineThread!
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        thread = EngineThread()
        thread.start()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LeiosStatsTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("statistics.json")
    }

    override func tearDownWithError() throws {
        thread.stop()
        thread = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// Stands in for the recorder, wired the way `EngineSubsystems` wires the real one: draining
    /// takes the next batch, discarding throws it away.
    private func flusher(_ batches: [StatsTotals]) -> StatsFlusher {
        var remaining = batches
        let flusher = StatsFlusher(thread: thread, fileURL: fileURL)
        flusher.drainBatch = { remaining.isEmpty ? StatsTotals() : remaining.removeFirst() }
        flusher.discardBatch = { if !remaining.isEmpty { remaining.removeFirst() } }
        return flusher
    }

    private func batch(clicks: Int) -> StatsTotals {
        var totals = StatsTotals()
        totals.counters.clicks = clicks
        totals.buttons["4"] = { var c = StatsButtonCounts(); c.clicks = clicks; return c }()
        totals.actions["navigateBack"] = clicks
        return totals
    }

    private func loaded() throws -> StatsArchive? {
        try StatsFile.load(from: fileURL)
    }

    private func flushAndWait(_ flusher: StatsFlusher) {
        let done = expectation(description: "flushed")
        flusher.flushNow { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testAFlushWritesTheBatchToDisk() throws {
        let flusher = flusher([batch(clicks: 7)])
        flushAndWait(flusher)

        let archive = try XCTUnwrap(loaded())
        XCTAssertEqual(archive.lifetime.counters.clicks, 7)
        XCTAssertEqual(archive.lifetime.buttons["4"]?.clicks, 7)
        XCTAssertEqual(archive.lifetime.actions["navigateBack"], 7)
        XCTAssertEqual(archive.hourly.count, 1)
        XCTAssertEqual(archive.daily.count, 1)
        XCTAssertEqual(archive.monthly.count, 1)
    }

    /// Several Macs' archives are summed by device identifier, so one has to exist and has to
    /// survive a restart — otherwise every launch would look like a new Mac.
    func testTheDeviceIdentityIsAssignedOnceAndKept() throws {
        let first = flusher([batch(clicks: 1)])
        flushAndWait(first)
        let id = try XCTUnwrap(loaded()).deviceID
        XCTAssertFalse(id.isEmpty)
        XCTAssertFalse(try XCTUnwrap(loaded()).deviceName.isEmpty)

        // A second flusher, as after a helper restart: same file, same identity.
        let second = flusher([batch(clicks: 1)])
        flushAndWait(second)
        let archive = try XCTUnwrap(loaded())
        XCTAssertEqual(archive.deviceID, id)
        XCTAssertEqual(archive.lifetime.counters.clicks, 2)
    }

    func testBatchesAccumulateAcrossFlushes() throws {
        let flusher = flusher([batch(clicks: 3), batch(clicks: 4), batch(clicks: 5)])
        for _ in 0..<3 { flushAndWait(flusher) }
        XCTAssertEqual(try XCTUnwrap(loaded()).lifetime.counters.clicks, 12)
    }

    func testAnEmptyBatchWritesNothing() {
        let flusher = flusher([])
        flushAndWait(flusher)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "an idle minute should not create a file")
    }

    /// `Engine.stop()` calls this, and the helper may exit the moment it returns, so the last
    /// batch has to be on disk by then rather than queued behind an async hop.
    func testStopWritesTheLastBatchSynchronously() throws {
        let flusher = flusher([batch(clicks: 9)])
        thread.performSync { flusher.stop() }
        XCTAssertEqual(try XCTUnwrap(loaded()).lifetime.counters.clicks, 9)
    }

    /// Reset throws away the file *and* whatever has been counted since the last flush. Letting
    /// the in-flight batch survive would put counts from before the reset into the fresh history.
    func testResetRemovesTheFileAndDiscardsWhatIsInFlight() throws {
        let flusher = flusher([batch(clicks: 6), batch(clicks: 99), batch(clicks: 2)])
        flushAndWait(flusher)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // The 99 is what the engine has counted between that flush and this reset.
        let reset = expectation(description: "reset")
        flusher.reset { reset.fulfill() }
        wait(for: [reset], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        flushAndWait(flusher)
        XCTAssertEqual(try XCTUnwrap(loaded()).lifetime.counters.clicks, 2,
                       "neither the old history nor the batch in flight should come back")
    }

    /// An unreadable archive is started over rather than kept. Counts are not the user's own work
    /// the way `config.json` is, and refusing to count is worse than losing what was counted.
    func testAnUnreadableFileIsStartedOver() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let flusher = flusher([batch(clicks: 4)])
        flushAndWait(flusher)
        XCTAssertEqual(try XCTUnwrap(loaded()).lifetime.counters.clicks, 4)
    }

    /// The periodic timer is what empties the accumulator in normal running; nothing else does.
    func testTheTimerDrainsOnItsOwn() throws {
        let flusher = StatsFlusher(thread: thread, fileURL: fileURL)
        let ticked = expectation(description: "ticked")
        ticked.assertForOverFulfill = false
        flusher.drainBatch = { self.batch(clicks: 1) }
        flusher.onPeriodicTick = { ticked.fulfill() }
        // The real cadence is a minute; this only has to prove the timer is wired to the drain.
        thread.performSync { flusher.start(interval: 0.1, leeway: .milliseconds(10)) }
        wait(for: [ticked], timeout: 5)
        thread.performSync { flusher.stop() }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(loaded()).lifetime.counters.clicks, 1)
    }
}
