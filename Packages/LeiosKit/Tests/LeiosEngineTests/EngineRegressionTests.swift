import XCTest
import AppKit
import CoreGraphics
@testable import LeiosEngine
@testable import LeiosShared

/// Regressions for engine bugs that the ported Mac Mouse Fix behaviour also has, so a later
/// re-sync against the original cannot quietly reintroduce them.
final class EngineRegressionTests: XCTestCase {

    // MARK: Buttons

    /// Pressing an unmapped button while a mapped one is held used to overwrite the shared
    /// `maxClickLevel` with 0, which made the mapped button's *release* look unmapped: it passed
    /// through to the system with no matching press, and the click cycle never ran the release
    /// callbacks that remove the button modifier.
    func testReleaseOfHeldButtonSurvivesAnUnmappedPressInBetween() {
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }

        let modifiers = Modifiers(runLoop: thread.runLoop)
        let table = RemapTable(buttons: [4: ButtonMapping(drag: .threeFingerSwipe)])
        let appCache = AppUnderPointerCache(thread: thread)
        let executor = ActionExecutor(touchSim: TouchSimulator(thread: thread), appUnderPointer: appCache)
        let event = CGEvent(source: nil)!

        var pressMappedSwallowed = false
        var pressUnmappedSwallowed = true
        var releaseMappedSwallowed = false
        var modifiersAfterRelease: [ButtonModifier] = []
        var buttons: Buttons?

        let done = expectation(description: "handled")
        thread.perform {
            let b = Buttons(thread: thread, modifiers: modifiers, remapTable: table, executor: executor)
            buttons = b
            pressMappedSwallowed = b.handleInput(device: 1, button: 4, down: true, event: event)
            XCTAssertEqual(modifiers.state.buttons.map(\.button), [4], "the held button should act as a modifier")
            pressUnmappedSwallowed = b.handleInput(device: 1, button: 6, down: true, event: event)
            releaseMappedSwallowed = b.handleInput(device: 1, button: 4, down: false, event: event)
            modifiersAfterRelease = modifiers.state.buttons
            b.killClickCycle()
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        XCTAssertNotNil(buttons)
        XCTAssertTrue(pressMappedSwallowed, "a mapped button's press is consumed")
        XCTAssertFalse(pressUnmappedSwallowed, "an unmapped button passes through")
        XCTAssertTrue(releaseMappedSwallowed, "the release must be consumed like its press was")
        XCTAssertTrue(modifiersAfterRelease.isEmpty, "releasing the button must clear its modifier, got \(modifiersAfterRelease)")
    }

    // MARK: SubPixelator

    /// A NaN delta has no sign, so the biased pixelator has no rounding function to choose and used
    /// to trap on the unwrap. The asserts that would catch NaN upstream are compiled out in Release.
    func testPixelatorSurvivesNaN() {
        let sp = SubPixelator.biased()
        XCTAssertEqual(sp.peekIntDelta(Double.nan), 0)
        XCTAssertEqual(sp.intDelta(Double.nan), 0)
        // Still picks up its bias from the first real input afterwards.
        XCTAssertEqual(sp.intDelta(0.3), 1)

        let vsp = VectorSubPixelator.biased()
        let out = vsp.intVector(Vector(x: Double.nan, y: -0.4))
        XCTAssertEqual(out.x, 0)
        XCTAssertEqual(out.y, -1)
    }

    // MARK: Bezier

    /// Above degree 20 the polynomial coefficients overflow `Int` while computing factorials, which
    /// traps even in Release. Sampling switches to de Casteljau at exactly that degree, so the
    /// coefficients are not needed there at all.
    func testHighDegreeBezierDoesNotOverflow() {
        let degree = 24
        let points = (0...degree).map { (Double($0) / Double(degree), Double($0) / Double(degree)) }
        let curve = Bezier(points: points, defaultEpsilon: 0.001)
        XCTAssertEqual(curve.degree, degree)
        XCTAssertEqual(curve.evaluate(at: 0), 0, accuracy: 1e-3)
        XCTAssertEqual(curve.evaluate(at: 1), 1, accuracy: 1e-3)
        XCTAssertEqual(curve.evaluate(at: 0.5), 0.5, accuracy: 1e-2)
    }

    // MARK: Frame clock

    /// The pool replaces its clocks on every screen-parameter change and tears the old ones down.
    /// An animator that subscribed to one of those would be marked running while no frame could ever
    /// arrive, which stops smooth scrolling until something else resets it.
    func testInvalidatedClockRefusesSubscribersSoAnimatorsCanPickAnother() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screens") }
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }

        let clock = CADisplayLinkClock(screen: screen, displayID: CGMainDisplayID(), runLoop: thread.foundationRunLoop)
        XCTAssertTrue(clock.isValid)
        let subscribedWhileLive = clock.subscribe(ObjectIdentifier(self)) { _ in }
        XCTAssertTrue(subscribedWhileLive)
        clock.unsubscribe(ObjectIdentifier(self))

        clock.invalidate()
        XCTAssertFalse(clock.isValid)
        let subscribedWhileDead = clock.subscribe(ObjectIdentifier(self)) { _ in }
        XCTAssertFalse(subscribedWhileDead, "a torn-down clock must report that it cannot deliver frames")
    }

    /// An animator handed a dead clock must not claim to be running, so the next tick starts a cold
    /// animation against a live clock instead of waiting on a frame that cannot come.
    func testAnimatorDoesNotRunOnADeadClock() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("no screens") }
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }

        let pool = FrameClockPool(engineRunLoop: thread.foundationRunLoop)
        pool.start()
        pool.stop() // every clock is now torn down, as after a screen-parameter change

        var isRunning = true
        let done = expectation(description: "started")
        thread.perform {
            let animator = TouchAnimator(clockPool: pool)
            animator.linkToMainScreen()
            animator.start(params: { _, _, _, _ in
                AnimatorStartParams(doStart: true, duration: 0.2, vector: Vector(x: 0, y: 120), curve: ScrollConfig.linearCurve)
            }, callback: { _, _, _ in })
            isRunning = animator.isRunning
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(isRunning, "an animator with no live clock must not report itself running")
    }

    /// A clock that dies *during* an animation — a display unplugged, or the pool rebuilding after
    /// a screen-parameter change — used to strand the animator: still marked running, so every
    /// later start took the running path, which never subscribes to a clock, and smooth scrolling
    /// stayed dead until something else happened to reset it.
    func testAnimatorRecoversWhenItsClockDiesMidAnimation() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("no screens") }
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }

        let pool = FrameClockPool(engineRunLoop: thread.foundationRunLoop)
        pool.start()
        defer { pool.stop() }

        let params: TouchAnimator.StartParamsCalculation = { _, _, _, _ in
            AnimatorStartParams(doStart: true, duration: 1.0, vector: Vector(x: 0, y: 600), curve: ScrollConfig.linearCurve)
        }
        let animator = thread.performSync { () -> TouchAnimator in
            let animator = TouchAnimator(clockPool: pool)
            animator.linkToMainScreen()
            animator.start(params: params, callback: { _, _, _ in })
            return animator
        }
        XCTAssertTrue(thread.performSync { animator.isRunning })

        // Every clock torn down under the running animation, then live ones put back.
        pool.stop()
        pool.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let framed = expectation(description: "frames after the next start")
        framed.assertForOverFulfill = false
        thread.perform {
            animator.start(params: params, callback: { _, phase, _ in
                if phase != .canceled { framed.fulfill() }
            })
        }
        wait(for: [framed], timeout: 2)
        thread.performSync { animator.cancel() }
    }
}
