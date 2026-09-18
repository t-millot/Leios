import XCTest
@testable import LeiosEngine
@testable import LeiosShared

final class ScrollAnalyzerTests: XCTestCase {

    private func config(smoothness: ScrollSettings.Smoothness = .high, precise: Bool = false) -> ScrollConfig {
        var s = ScrollSettings()
        s.smoothness = smoothness
        s.precise = precise
        return ScrollConfig(settings: s)
    }

    func testConsecutiveTicksAndSwipes() {
        let analyzer = ScrollAnalyzer()
        var clock = 100.0
        let cfg = config()

        var r = analyzer.update(tickAt: clock, direction: .down, config: cfg)
        XCTAssertEqual(r.consecutiveScrollTickCounter, 0)
        XCTAssertEqual(r.timeBetweenTicks, .greatestFiniteMagnitude)
        XCTAssertFalse(r.scrollDirectionDidChange)

        clock += 0.02
        r = analyzer.update(tickAt: clock, direction: .down, config: cfg)
        XCTAssertEqual(r.consecutiveScrollTickCounter, 1)
        XCTAssertLessThan(r.timeBetweenTicks, cfg.consecutiveScrollTickIntervalMax)

        clock += 0.02
        r = analyzer.update(tickAt: clock, direction: .down, config: cfg)
        XCTAssertEqual(r.consecutiveScrollTickCounter, 2)

        // Gap > tickIntervalMax but < swipeMaxInterval, and ≥ 12 ticks/s on average → new swipe, counter increments.
        clock += 0.2
        XCTAssertTrue(analyzer.peekIsFirstConsecutiveTick(at: clock, direction: .down, config: cfg))
        r = analyzer.update(tickAt: clock, direction: .down, config: cfg)
        XCTAssertEqual(r.consecutiveScrollTickCounter, 0)
        XCTAssertEqual(r.consecutiveScrollSwipeCounter, 1)
        XCTAssertEqual(r.timeBetweenTicks, .greatestFiniteMagnitude)

        // Direction change resets everything.
        clock += 0.05
        r = analyzer.update(tickAt: clock, direction: .up, config: cfg)
        XCTAssertTrue(r.scrollDirectionDidChange)
        XCTAssertEqual(r.consecutiveScrollTickCounter, 0)
        XCTAssertEqual(r.consecutiveScrollSwipeCounter, 0)
    }

    func testSwipeNotCountedWhenTooFewTicks() {
        let analyzer = ScrollAnalyzer()
        var clock = 10.0
        let cfg = config()
        _ = analyzer.update(tickAt: clock, direction: .down, config: cfg)   // single tick
        clock += 0.3
        let r = analyzer.update(tickAt: clock, direction: .down, config: cfg)
        XCTAssertEqual(r.consecutiveScrollSwipeCounter, 0, "a 1-tick swipe is below scrollSwipeThreshold_inTicks")
    }

    func testSmoothingPreSeedOnlyForHighNonPrecise() {
        let high = config(smoothness: .high)
        let regular = config(smoothness: .regular)
        for (cfg, expectSeeded) in [(high, true), (regular, false)] {
            let analyzer = ScrollAnalyzer()
            var clock = 1.0
            _ = analyzer.update(tickAt: clock, direction: .down, config: cfg)
            clock += 0.02
            let r = analyzer.update(tickAt: clock, direction: .down, config: cfg)
            if expectSeeded {
                XCTAssertEqual(r.timeBetweenTicks, (0.160 + 0.02) / 2, accuracy: 1e-9)
            } else {
                XCTAssertEqual(r.timeBetweenTicks, 0.02, accuracy: 1e-9)
            }
        }
    }

    func testDirectionHelper() {
        XCTAssertEqual(ScrollController.direction(axis: .vertical, delta: -1, invert: -1, horizontalModifier: false), .up)
        XCTAssertEqual(ScrollController.direction(axis: .vertical, delta: -1, invert: 1, horizontalModifier: false), .down)
        XCTAssertEqual(ScrollController.direction(axis: .horizontal, delta: 1, invert: 1, horizontalModifier: false), .right)
        XCTAssertEqual(ScrollController.direction(axis: .vertical, delta: 1, invert: 1, horizontalModifier: true), .right)
    }
}
