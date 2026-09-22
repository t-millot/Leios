import XCTest
import AppKit
@testable import LeiosEngine

/// Verifies the core threading assumption: CADisplayLinks created on the main thread deliver frames on the engine run loop.
final class FrameClockTests: XCTestCase {

    func testAnimatorRunsOnEngineThreadWithDisplayLink() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("no screens") }
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }

        let pool = FrameClockPool(engineRunLoop: thread.foundationRunLoop)
        pool.start()
        defer { pool.stop() }
        XCTAssertNotNil(pool.clock(for: CGMainDisplayID()))

        let done = expectation(description: "animation ended")
        var frames = 0
        var phases: [AnimationCallbackPhase] = []
        var onEngineThread = true
        var total = Vector.zero
        var animator: TouchAnimator?

        thread.perform {
            let a = TouchAnimator(clockPool: pool)
            animator = a
            a.link(to: CGMainDisplayID())
            a.start(params: { _, _, _, _ in
                AnimatorStartParams(doStart: true, duration: 0.2, vector: Vector(x: 0, y: 120), curve: ScrollConfig.linearCurve)
            }, callback: { delta, phase, _ in
                frames += 1
                phases.append(phase)
                total = added(total, delta)
                if !thread.isCurrent { onEngineThread = false }
                if phase == .end || phase == .canceled { done.fulfill() }
            })
        }

        wait(for: [done], timeout: 3)
        XCTAssertTrue(onEngineThread, "frame callbacks must arrive on the engine thread")
        XCTAssertGreaterThanOrEqual(frames, 5, "expected several frames over 200 ms, got \(frames)")
        XCTAssertEqual(phases.first, .start)
        XCTAssertEqual(phases.last, .end)
        XCTAssertEqual(total.y, 120, accuracy: 0.5)
        XCTAssertEqual(total.x, 0)
        XCTAssertNotNil(animator)
        XCTAssertFalse(animator!.isRunning)
    }

    /// A scroll that begins on another display while the last glide is still running must move
    /// that animation to the new display's clock — it used to finish at the old display's rate, and
    /// the wheel ticks that followed kept it running there, so a 120 Hz screen scrolled at 60 fps.
    /// The switch must not lose distance or step backwards when the new clock's next frame falls
    /// inside the old clock's last one.
    func testRunningAnimationMovesToAnotherDisplaysClock() throws {
        let displays = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        guard displays.count >= 2 else { throw XCTSkip("needs two displays") }
        let (from, to) = (displays[0], displays[1])

        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }

        let pool = FrameClockPool(engineRunLoop: thread.foundationRunLoop)
        pool.start()
        defer { pool.stop() }
        let fromClock = try XCTUnwrap(pool.clock(for: from))
        let toClock = try XCTUnwrap(pool.clock(for: to))
        XCTAssertFalse(fromClock === toClock)

        let done = expectation(description: "animation ended")
        var frameTimes: [CFTimeInterval] = []
        var deltas: [Double] = []
        var framesBeforeSwitch = 0
        var animator: TouchAnimator?

        thread.perform {
            let a = TouchAnimator(clockPool: pool)
            animator = a
            a.link(to: from)
            a.start(params: { _, _, _, _ in
                AnimatorStartParams(doStart: true, duration: 0.6, vector: Vector(x: 0, y: 600), curve: ScrollConfig.linearCurve)
            }, callback: { delta, phase, _ in
                frameTimes.append(CACurrentMediaTime())
                deltas.append(delta.y)
                if deltas.count == 8 {
                    XCTAssertTrue(a.clock === fromClock)
                    a.link(to: to)
                    // The old clock keeps driving until the new one has ticked.
                    XCTAssertTrue(a.clock === fromClock)
                    framesBeforeSwitch = frameTimes.count
                }
                if phase == .end || phase == .canceled { done.fulfill() }
            })
        }

        wait(for: [done], timeout: 3)
        let a = try XCTUnwrap(animator)
        XCTAssertTrue(thread.performSync { a.clock === toClock }, "the running animation must end up on the new display's clock")
        XCTAssertEqual(deltas.reduce(0, +), 600, accuracy: 0.5, "switching clocks must not lose or add distance")
        XCTAssertTrue(deltas.allSatisfy { $0 >= 0 }, "no frame may step backwards across the switch: \(deltas)")

        // Only meaningful when the two displays run at clearly different rates.
        let fromPeriod = fromClock.nominalTimeBetweenFrames
        let toPeriod = toClock.nominalTimeBetweenFrames
        guard abs(fromPeriod - toPeriod) / max(fromPeriod, toPeriod) > 0.25 else { return }
        let after = Array(frameTimes[framesBeforeSwitch...])
        let intervals = zip(after.dropFirst(), after).map { $0 - $1 }.sorted()
        let median = intervals[intervals.count / 2]
        XCTAssertLessThan(abs(median - toPeriod), abs(median - fromPeriod), "frames after the switch should come at the new display's rate (median \(median * 1000) ms)")
    }
}
