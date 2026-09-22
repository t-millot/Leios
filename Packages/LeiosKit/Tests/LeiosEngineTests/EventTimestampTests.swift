import XCTest
import CoreGraphics
import QuartzCore
@testable import LeiosEngine

/// Real hardware stamps events in mach ticks, synthetic events in nanoseconds; both must read as
/// the same seconds-since-boot. Numbers below are from a live probe on Apple silicon: a real
/// mouse event read as nanoseconds came out 356,154 s old, read as ticks 3 ms old.
final class EventTimestampTests: XCTestCase {

    private let appleSilicon = mach_timebase_info_data_t(numer: 125, denom: 3)
    private let intel = mach_timebase_info_data_t(numer: 1, denom: 1)

    /// ~4 days of uptime, in 24 MHz ticks.
    private let nowTicks: UInt64 = 8_754_277_924_205

    func testHardwareTicksOnAppleSilicon() {
        let eventTicks = nowTicks - 72000 // 3 ms earlier
        let now = EventUtility.seconds(fromEventTimestamp: nowTicks, nowTicks: nowTicks, timebase: appleSilicon)
        let t = EventUtility.seconds(fromEventTimestamp: eventTicks, nowTicks: nowTicks, timebase: appleSilicon)
        XCTAssertEqual(now - t, 0.003, accuracy: 1e-6)
    }

    func testSyntheticNanosecondsOnAppleSilicon() {
        let nowNs = UInt64(Double(nowTicks) * 125 / 3)
        let t = EventUtility.seconds(fromEventTimestamp: nowNs - 500_000, nowTicks: nowTicks, timebase: appleSilicon)
        XCTAssertEqual(Double(nowNs) / 1e9 - t, 0.0005, accuracy: 1e-6)
    }

    /// The bug: a real wheel pausing 5 s between swipes read as 0.12 s, inside
    /// `consecutiveScrollTickIntervalMax`, so the pause never started a new sequence.
    func testIntervalBetweenHardwareTicksIsNotShrunk() {
        let first = EventUtility.seconds(fromEventTimestamp: nowTicks - 120_000_000, nowTicks: nowTicks - 120_000_000, timebase: appleSilicon)
        let second = EventUtility.seconds(fromEventTimestamp: nowTicks, nowTicks: nowTicks, timebase: appleSilicon)
        XCTAssertEqual(second - first, 5, accuracy: 1e-6)
    }

    func testIntelUnitsAgree() {
        let t = EventUtility.seconds(fromEventTimestamp: nowTicks - 1_000_000, nowTicks: nowTicks, timebase: intel)
        XCTAssertEqual(Double(nowTicks) / 1e9 - t, 0.001, accuracy: 1e-9)
    }

    /// End to end on this machine's clock: either stamp reads as `CACurrentMediaTime()`.
    func testLiveEventReadsOnMediaTimeClock() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        event.timestamp = mach_absolute_time()
        XCTAssertEqual(event.timestampSeconds, CACurrentMediaTime(), accuracy: 0.05)
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        XCTAssertEqual(event.timestampSeconds, CACurrentMediaTime(), accuracy: 0.05)
    }
}
