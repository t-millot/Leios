import XCTest
@testable import LeiosEngine

final class ClickCycleTests: XCTestCase {

    private var thread: EngineThread!
    private var retainedCycle: ClickCycle?

    override func setUp() {
        thread = EngineThread()
        thread.start()
    }

    override func tearDown() {
        thread.stop()
    }

    private func run(_ block: @escaping (ClickCycle, @escaping (ClickCycle.TriggerPhase, Int) -> Void) -> Void, duration: TimeInterval) -> [(ClickCycle.TriggerPhase, Int)] {
        var log: [(ClickCycle.TriggerPhase, Int)] = []
        let done = expectation(description: "done")
        thread.perform {
            let cycle = ClickCycle(thread: self.thread)
            self.retainedCycle = cycle
            block(cycle) { phase, level in log.append((phase, level)) }
            self.thread.scheduleTimer(after: duration) { done.fulfill() }
        }
        wait(for: [done], timeout: duration + 2)
        return log
    }

    func testSimpleClick() {
        let log = run({ cycle, record in
            let trigger: ClickCycle.TriggerCallback = { phase, level, _, _, _ in record(phase, level) }
            cycle.handleClick(device: 1, button: 4, down: true, maxClickLevel: 1, trigger: trigger)
            cycle.handleClick(device: 1, button: 4, down: false, maxClickLevel: 1, trigger: trigger)
        }, duration: 0.4)
        XCTAssertEqual(log.map { $0.0 }, [.press, .release, .levelExpired])
        XCTAssertEqual(log.map { $0.1 }, [1, 1, 1])
    }

    func testHold() {
        let log = run({ cycle, record in
            let trigger: ClickCycle.TriggerCallback = { phase, level, _, _, _ in record(phase, level) }
            cycle.handleClick(device: 1, button: 4, down: true, maxClickLevel: 1, trigger: trigger)
            self.thread.scheduleTimer(after: 0.35) {
                cycle.handleClick(device: 1, button: 4, down: false, maxClickLevel: 1, trigger: trigger)
            }
        }, duration: 0.7)
        XCTAssertEqual(log.map { $0.0 }, [.press, .hold, .releaseFromHold])
    }

    func testDoubleClickLevels() {
        let log = run({ cycle, record in
            let trigger: ClickCycle.TriggerCallback = { phase, level, _, _, _ in record(phase, level) }
            cycle.handleClick(device: 1, button: 4, down: true, maxClickLevel: 2, trigger: trigger)
            cycle.handleClick(device: 1, button: 4, down: false, maxClickLevel: 2, trigger: trigger)
            self.thread.scheduleTimer(after: 0.1) {
                cycle.handleClick(device: 1, button: 4, down: true, maxClickLevel: 2, trigger: trigger)
                cycle.handleClick(device: 1, button: 4, down: false, maxClickLevel: 2, trigger: trigger)
            }
        }, duration: 0.6)
        XCTAssertEqual(log.map { $0.0 }, [.press, .release, .press, .release, .levelExpired])
        XCTAssertEqual(log.map { $0.1 }, [1, 1, 2, 2, 2])
    }

    func testReleaseCallbacksFireOnUp() {
        var released = false
        let log = run({ cycle, record in
            let trigger: ClickCycle.TriggerCallback = { phase, level, _, _, onRelease in
                record(phase, level)
                if phase == .press { onRelease.append { released = true } }
            }
            cycle.handleClick(device: 1, button: 4, down: true, maxClickLevel: 1, trigger: trigger)
            cycle.kill()   // e.g. the button had an effect as a modifier
            cycle.handleClick(device: 1, button: 4, down: false, maxClickLevel: 1, trigger: trigger)
        }, duration: 0.3)
        XCTAssertEqual(log.map { $0.0 }, [.press])   // lonely release → no release trigger
        XCTAssertTrue(released)
    }
}
