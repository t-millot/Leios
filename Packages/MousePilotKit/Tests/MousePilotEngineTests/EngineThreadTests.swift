import XCTest
@testable import MousePilotEngine

final class EngineThreadTests: XCTestCase {

    func testPerformRunsOnEngineThreadInOrder() {
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }
        var order: [Int] = []
        let done = expectation(description: "done")
        thread.perform { order.append(1) }
        thread.perform { order.append(2) }
        thread.perform {
            order.append(3)
            XCTAssertTrue(thread.isCurrent)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(order, [1, 2, 3])
    }

    func testPerformSyncReturnsValue() {
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }
        let value = thread.performSync { 42 }
        XCTAssertEqual(value, 42)
    }

    func testTimerFires() {
        let thread = EngineThread()
        thread.start()
        defer { thread.stop() }
        let fired = expectation(description: "fired")
        thread.perform {
            thread.scheduleTimer(after: 0.05) {
                XCTAssertTrue(thread.isCurrent)
                fired.fulfill()
            }
        }
        wait(for: [fired], timeout: 2)
    }
}
