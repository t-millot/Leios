import XCTest
import CoreGraphics
@testable import MousePilotEngine

/// The cache is transparent by design — its only effect is that the window-list walk runs less
/// often — so these assert on `lookupCount` rather than on wall-clock time, which would flake on a
/// CI runner with almost no windows open.
final class AppUnderPointerCacheTests: XCTestCase {

    /// Runs `body` on the engine thread, since the cache asserts thread confinement.
    private func withCache(_ body: @escaping (AppUnderPointerCache) -> Void) {
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }
        let cache = AppUnderPointerCache(thread: thread)
        thread.performSync { body(cache) }
    }

    /// A synthetic event pins the pointer location, so the test does not depend on where the real
    /// cursor happens to be or on it holding still.
    private func event(at point: CGPoint) -> CGEvent {
        let e = CGEvent(source: nil)!
        e.location = point
        return e
    }

    func testRepeatedLookupAtSamePointHitsCache() {
        withCache { cache in
            let e = self.event(at: CGPoint(x: 100, y: 100))
            _ = cache.bundleID(event: e)
            XCTAssertEqual(cache.lookupCount, 1)
            for _ in 0..<20 { _ = cache.bundleID(event: e) }
            XCTAssertEqual(cache.lookupCount, 1, "a parked pointer must not re-walk the window list")
        }
    }

    func testSubPixelMovementStillHitsCache() {
        withCache { cache in
            _ = cache.bundleID(event: self.event(at: CGPoint(x: 100.1, y: 100.2)))
            _ = cache.bundleID(event: self.event(at: CGPoint(x: 100.9, y: 100.7)))
            XCTAssertEqual(cache.lookupCount, 1, "the key is floored to a whole pixel")
        }
    }

    func testMovingPointerMissesCache() {
        withCache { cache in
            _ = cache.bundleID(event: self.event(at: CGPoint(x: 100, y: 100)))
            _ = cache.bundleID(event: self.event(at: CGPoint(x: 400, y: 400)))
            XCTAssertEqual(cache.lookupCount, 2)
            _ = cache.bundleID(event: self.event(at: CGPoint(x: 100, y: 100)))
            XCTAssertEqual(cache.lookupCount, 3, "only the most recent point is cached")
        }
    }

    func testInvalidateForcesRefresh() {
        withCache { cache in
            let e = self.event(at: CGPoint(x: 100, y: 100))
            _ = cache.bundleID(event: e)
            _ = cache.bundleID(event: e)
            XCTAssertEqual(cache.lookupCount, 1)
            cache.invalidate()
            _ = cache.bundleID(event: e)
            XCTAssertEqual(cache.lookupCount, 2, "invalidation must drop the entry, not just the point")
        }
    }

    func testCachedAnswerMatchesUncached() {
        withCache { cache in
            for point in [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 300), CGPoint(x: -50, y: -50)] {
                let expected = EventUtility.bundleIDOfApp(at: point)
                let cached = cache.bundleID(event: self.event(at: point))
                XCTAssertEqual(cached, expected, "cache changed the answer at \(point)")
                XCTAssertEqual(cache.bundleID(event: self.event(at: point)), expected, "hit disagrees with miss")
            }
        }
    }

    func testObserverLifecycleIsIdempotent() {
        withCache { cache in
            cache.startObserving()
            cache.startObserving()
            _ = cache.bundleID(event: self.event(at: CGPoint(x: 100, y: 100)))
            XCTAssertEqual(cache.lookupCount, 1)
            cache.stopObserving()
            cache.stopObserving()
            // stopObserving clears the entry, so this is a fresh walk.
            _ = cache.bundleID(event: self.event(at: CGPoint(x: 100, y: 100)))
            XCTAssertEqual(cache.lookupCount, 2)
        }
    }
}
