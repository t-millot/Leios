import XCTest
@testable import MousePilotEngine

final class SubPixelatorTests: XCTestCase {

    func testRoundPixelatorSumsMatch() {
        let sp = SubPixelator.round()
        var sumIn = 0.0, sumOut = 0.0
        for _ in 0..<1000 {
            let v = Double.random(in: -3...3)
            sumIn += v
            let o = sp.intDelta(v)
            XCTAssertEqual(o, o.rounded())
            sumOut += o
        }
        XCTAssertEqual(sumIn, sumOut, accuracy: 0.5)
    }

    func testBiasedPixelatorFirstOutputNonZero() {
        let sp = SubPixelator.biased()
        XCTAssertEqual(sp.intDelta(0.1), 1)   // ceil for positive
        sp.reset()
        XCTAssertEqual(sp.peekIntDelta(-0.1), -1)
        XCTAssertEqual(sp.intDelta(-0.1), -1) // floor for negative
        XCTAssertEqual(sp.peekIntDelta(-0.1), 0) // accumulated error now 0.9
    }

    func testThresholdDisablesPixelation() {
        let sp = SubPixelator.round()
        sp.threshold = 5
        XCTAssertEqual(sp.intDelta(7.3), 7.3)
        XCTAssertEqual(sp.intDelta(2.3), 2)
    }

    func testVectorPixelator() {
        let v = VectorSubPixelator.biased()
        let out = v.intVector(Vector(x: 0.4, y: -0.4))
        XCTAssertEqual(out, Vector(x: 1, y: -1))
        XCTAssertEqual(v.peekIntVector(Vector(x: 0.6, y: -0.6)), Vector(x: 0, y: 0))
    }

    func testRollingAverage() {
        let avg = RollingAverage(capacity: 3)
        XCTAssertEqual(avg.smooth(value: 1), 1)
        XCTAssertEqual(avg.smooth(value: 3), 2)
        XCTAssertEqual(avg.smooth(value: 5), 3)
        XCTAssertEqual(avg.smooth(value: 7), 5)
        avg.reset()
        XCTAssertEqual(avg.smooth(value: 10), 10)
        let seeded = RollingAverage(capacity: 3, initialValues: [0.16])
        XCTAssertEqual(seeded.smooth(value: 0.02), 0.09, accuracy: 1e-9)
    }
}
