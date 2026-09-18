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
            a.linkToMainScreen()
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
}
