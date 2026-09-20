import XCTest
import CoreGraphics
@testable import LeiosEngine
@testable import LeiosShared

/// The recorder is a plain accumulator, so its arithmetic is testable without ever creating an
/// event tap — which no suite in this package can do (see CLAUDE.md). What the tap itself feeds it
/// is covered by the manual checks in the plan.
final class StatsRecorderTests: XCTestCase {

    private var thread: EngineThread!
    private var recorder: StatsRecorder!

    override func setUp() {
        super.setUp()
        thread = EngineThread()
        thread.start()
        recorder = thread.performSync { StatsRecorder(thread: self.thread) }
    }

    override func tearDown() {
        recorder = nil
        thread.stop()
        thread = nil
        super.tearDown()
    }

    /// Everything the recorder does must happen on the engine thread, so every test body does.
    private func onEngine<T>(_ body: @escaping (StatsRecorder) -> T) -> T {
        let recorder = self.recorder!
        return thread.performSync { body(recorder) }
    }

    // MARK: Scroll

    func testScrollTicksAreCountedByDirection() {
        let batch = onEngine { recorder in
            for i in 0..<100 {
                recorder.recordScrollInput(deltaAxis1: 10, deltaAxis2: 0, isContinuous: false,
                                           at: Double(i) * 0.05)
            }
            recorder.recordScrollInput(deltaAxis1: -10, deltaAxis2: 0, isContinuous: false, at: 100)
            recorder.recordScrollInput(deltaAxis1: 0, deltaAxis2: 7, isContinuous: false, at: 200)
            recorder.recordScrollInput(deltaAxis1: 0, deltaAxis2: -7, isContinuous: false, at: 300)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.inTicksUp, 100)
        XCTAssertEqual(batch.counters.inPointsUp, 1000)
        XCTAssertEqual(batch.counters.inTicksDown, 1)
        XCTAssertEqual(batch.counters.inTicksLeft, 1)
        XCTAssertEqual(batch.counters.inPointsLeft, 7)
        XCTAssertEqual(batch.counters.inTicksRight, 1)
        XCTAssertEqual(batch.counters.inPointsRight, 7)
    }

    func testAZeroDeltaCountsNoTick() {
        let batch = onEngine { recorder in
            recorder.recordScrollInput(deltaAxis1: 0, deltaAxis2: 0, isContinuous: false, at: 1)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.inTicks, 0)
    }

    func testTicksWithinTheGapAreOneSequence() {
        let batch = onEngine { recorder in
            for i in 0..<10 {
                recorder.recordScrollInput(deltaAxis1: 10, deltaAxis2: 0, isContinuous: false,
                                           at: Double(i) * 0.05)
            }
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.scrollSequences, 1)
        XCTAssertEqual(batch.counters.inTicksUp, 10)
    }

    /// The regression that made the figure read low: two flicks a third of a second apart are two
    /// flicks. They were one while the gap was `ScrollController.sequenceGap`, which is ten times
    /// longer and measures how stale the app-under-pointer lookup may get, not wheel motion.
    func testFlicksATwoThirdsOfASecondApartAreNotMerged() {
        let batch = onEngine { recorder in
            for i in 0..<4 {
                // Four flicks of three ticks each, 0.3 s between them — an ordinary cadence.
                for tick in 0..<3 {
                    recorder.recordScrollInput(deltaAxis1: -10, deltaAxis2: 0, isContinuous: false,
                                               at: Double(i) * 0.3 + Double(tick) * 0.03)
                }
            }
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.inTicksDown, 12)
        XCTAssertEqual(batch.counters.scrollSequences, 4)
    }

    /// And the gap is the engine's, so a run the engine treats as consecutive is one flick here.
    func testTicksInsideTheEngineGapAreOneFlick() {
        let batch = onEngine { recorder in
            for i in 0..<12 {
                recorder.recordScrollInput(deltaAxis1: -10, deltaAxis2: 0, isContinuous: false,
                                           at: Double(i) * (StatsCounters.sequenceGap * 0.9))
            }
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.scrollSequences, 1)
    }

    func testAGapStartsANewSequence() {
        let batch = onEngine { recorder in
            recorder.recordScrollInput(deltaAxis1: 10, deltaAxis2: 0, isContinuous: false, at: 0)
            recorder.recordScrollInput(deltaAxis1: 10, deltaAxis2: 0, isContinuous: false,
                                       at: StatsCounters.sequenceGap + 0.1)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.scrollSequences, 2)
    }

    /// A trackpad produces dozens of events per swipe and the engine never touches them, so they
    /// are kept out of the wheel figures they would otherwise swamp.
    func testContinuousScrollIsCountedApart() {
        let batch = onEngine { recorder in
            for _ in 0..<30 {
                recorder.recordScrollInput(deltaAxis1: 3, deltaAxis2: 0, isContinuous: true, at: 0)
            }
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.continuousEvents, 30)
        XCTAssertEqual(batch.counters.continuousPoints, 90)
        XCTAssertEqual(batch.counters.inTicks, 0)
        XCTAssertEqual(batch.counters.scrollSequences, 0)
    }

    func testOutputPointsAreCountedByDirectionAndAlwaysPositive() {
        let batch = onEngine { recorder in
            recorder.recordScrollOutput(points: 120, direction: .down)
            recorder.recordScrollOutput(points: 80, direction: .down)
            recorder.recordScrollOutput(points: 30, direction: .right)
            recorder.recordScrollOutput(points: 10, direction: .none)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.outPointsDown, 200)
        XCTAssertEqual(batch.counters.outPointsRight, 30)
        XCTAssertEqual(batch.counters.outPoints, 230)
    }

    // MARK: Clicks

    func testEveryPressIsCountedPerButton() {
        let batch = onEngine { recorder in
            recorder.recordClick(button: 1, at: .zero, time: 0)
            recorder.recordClick(button: 1, at: .zero, time: 10)
            recorder.recordClick(button: 4, at: .zero, time: 20)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.clicks, 3)
        XCTAssertEqual(batch.buttons["1"]?.clicks, 2)
        XCTAssertEqual(batch.buttons["4"]?.clicks, 1)
    }

    func testTwoQuickPressesAreADoubleClick() {
        let batch = onEngine { recorder in
            recorder.recordClick(button: 1, at: .zero, time: 0)
            recorder.recordClick(button: 1, at: .zero, time: 0.1)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.clicks, 2)
        XCTAssertEqual(batch.counters.doubleClicks, 1)
        XCTAssertEqual(batch.buttons["1"]?.doubleClicks, 1)
    }

    func testThreeQuickPressesAreADoubleAndATriple() {
        let batch = onEngine { recorder in
            for i in 0..<3 { recorder.recordClick(button: 1, at: .zero, time: Double(i) * 0.1) }
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.clicks, 3)
        XCTAssertEqual(batch.counters.doubleClicks, 1)
        XCTAssertEqual(batch.counters.tripleClicks, 1)
    }

    func testSlowPressesAreSeparateClicks() {
        let batch = onEngine { recorder in
            recorder.recordClick(button: 1, at: .zero, time: 0)
            recorder.recordClick(button: 1, at: .zero, time: 5)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.clicks, 2)
        XCTAssertEqual(batch.counters.doubleClicks, 0)
    }

    func testAQuickPressOfADifferentButtonIsNotADoubleClick() {
        let batch = onEngine { recorder in
            recorder.recordClick(button: 1, at: .zero, time: 0)
            recorder.recordClick(button: 2, at: .zero, time: 0.05)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.doubleClicks, 0)
    }

    func testAQuickPressSomewhereElseIsNotADoubleClick() {
        let batch = onEngine { recorder in
            recorder.recordClick(button: 1, at: .zero, time: 0)
            recorder.recordClick(button: 1, at: CGPoint(x: 400, y: 200), time: 0.05)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.doubleClicks, 0)
    }

    // MARK: Actions and holds

    func testActionsAreTalliedByStableKeyAndByButton() {
        let batch = onEngine { recorder in
            recorder.recordButtonAction(button: 4, duration: .click, action: .navigateBack)
            recorder.recordButtonAction(button: 4, duration: .click, action: .navigateBack)
            recorder.recordButtonAction(button: 5, duration: .hold, action: .symbolicHotkey(.missionControl))
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.actions, 3)
        XCTAssertEqual(batch.actions["navigateBack"], 2)
        XCTAssertEqual(batch.actions["symbolicHotkey.missionControl"], 1)
        XCTAssertEqual(batch.buttons["4"]?.actions, 2)
        XCTAssertEqual(batch.buttons["5"]?.actions, 1)
    }

    func testOnlyHeldTriggersCountAsHolds() {
        let batch = onEngine { recorder in
            recorder.recordButtonAction(button: 4, duration: .click, action: .smartZoom)
            recorder.recordButtonAction(button: 4, duration: .hold, action: .smartZoom)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.holds, 1)
        XCTAssertEqual(batch.buttons["4"]?.holds, 1)
        XCTAssertEqual(batch.counters.actions, 2)
    }

    // MARK: Drags

    func testDragsAreCountedByGesture() {
        let batch = onEngine { recorder in
            recorder.recordDragStart(gesture: .twoFingerSwipe)
            recorder.recordDragEnd(gesture: .twoFingerSwipe, points: 250.5, seconds: 1.5)
            recorder.recordDragStart(gesture: .threeFingerSwipe)
            recorder.recordDragEnd(gesture: .threeFingerSwipe, points: 100, seconds: 0.5)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.dragStarts, 2)
        XCTAssertEqual(batch.counters.dragPoints, 350.5)
        XCTAssertEqual(batch.counters.dragSeconds, 2)
        XCTAssertEqual(batch.drags["twoFingerSwipe"]?.starts, 1)
        XCTAssertEqual(batch.drags["twoFingerSwipe"]?.points, 250.5)
        XCTAssertEqual(batch.drags["threeFingerSwipe"]?.points, 100)
    }

    // MARK: Draining

    func testDrainEmptiesTheAccumulator() {
        let (first, second) = onEngine { recorder -> (StatsTotals, StatsTotals) in
            recorder.recordClick(button: 1, at: .zero, time: 0)
            return (recorder.drain(), recorder.drain())
        }
        XCTAssertEqual(first.counters.clicks, 1)
        XCTAssertTrue(second.isEmpty)
    }

    func testDiscardThrowsTheBatchAway() {
        let batch = onEngine { recorder -> StatsTotals in
            recorder.recordClick(button: 1, at: .zero, time: 0)
            recorder.discard()
            return recorder.drain()
        }
        XCTAssertTrue(batch.isEmpty)
    }

    /// Switching statistics off and on again must not resurrect a half-finished sequence or a
    /// click level from before the gap.
    func testDiscardResetsRecognitionState() {
        let batch = onEngine { recorder -> StatsTotals in
            recorder.recordScrollInput(deltaAxis1: 10, deltaAxis2: 0, isContinuous: false, at: 0)
            recorder.discard()
            recorder.recordScrollInput(deltaAxis1: 10, deltaAxis2: 0, isContinuous: false, at: 0.01)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.scrollSequences, 1)
    }
}

/// Regression coverage for the teardown path, which is where the counts of a short session live
/// or die: `SwitchMaster.disableAll()` turns the tap off on the way out of `EngineSubsystems.stop()`,
/// immediately before the flusher's final write.
final class StatsTapTeardownTests: XCTestCase {

    func testTurningTheTapOffKeepsWhatWasCounted() {
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }

        let batch: StatsTotals = thread.performSync {
            let recorder = StatsRecorder(thread: thread)
            let tap = StatsTap(thread: thread, recorder: recorder)
            recorder.recordClick(button: 1, at: .zero, time: 0)
            recorder.recordScrollInput(deltaAxis1: -10, deltaAxis2: 0, isContinuous: false, at: 1)
            // No tap was created, so this only exercises the bookkeeping — which is the part that
            // used to throw the batch away and take a whole session's counts with it.
            tap.setReceiving(false)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.clicks, 1)
        XCTAssertEqual(batch.counters.inTicksDown, 1)
    }
}

/// The statistics switch has to reach every way in, not only the tap. Scroll output, actions and
/// drags are recorded from inside subsystems that keep running whatever the switch says.
final class StatsRecorderSwitchTests: XCTestCase {

    private var thread: EngineThread!

    override func setUp() {
        super.setUp()
        thread = EngineThread()
        thread.start()
    }

    override func tearDown() {
        thread.stop()
        thread = nil
        super.tearDown()
    }

    func testNothingIsCountedWhileTheSwitchIsOff() {
        let batch: StatsTotals = thread.performSync {
            let recorder = StatsRecorder(thread: self.thread)
            recorder.setEnabled(false)
            recorder.recordScrollInput(deltaAxis1: -10, deltaAxis2: 0, isContinuous: false, at: 0)
            recorder.recordScrollOutput(points: 400, direction: .down)
            recorder.recordClick(button: 1, at: .zero, time: 0)
            recorder.recordButtonAction(button: 4, duration: .click, action: .middleClick)
            recorder.recordDragStart(gesture: .twoFingerSwipe)
            recorder.recordDragEnd(gesture: .twoFingerSwipe, points: 100, seconds: 1)
            return recorder.drain()
        }
        XCTAssertTrue(batch.isEmpty, "the switch let something through: \(batch)")
    }

    func testCountingResumesWhenTheSwitchGoesBackOn() {
        let batch: StatsTotals = thread.performSync {
            let recorder = StatsRecorder(thread: self.thread)
            recorder.setEnabled(false)
            recorder.recordClick(button: 1, at: .zero, time: 0)
            recorder.setEnabled(true)
            recorder.recordClick(button: 1, at: .zero, time: 10)
            return recorder.drain()
        }
        XCTAssertEqual(batch.counters.clicks, 1)
    }
}
