@testable import InversoKit
import XCTest

final class ScrollSmootherTests: XCTestCase {
    func testSingleImpulseUsesCriticalDampingAndSettlesExactly() {
        var smoother = ScrollSmoother()
        XCTAssertTrue(smoother.enqueue(delta: 10, at: 0))
        XCTAssertTrue(smoother.isActive)
        XCTAssertEqual(smoother.advance(at: 0), 0)
        // At omega * time = 1 the delivered fraction is 1 - 2/e.
        let first = smoother.advance(at: 0.01)
        XCTAssertEqual(first, 2.6424111765711533, accuracy: 1e-12)
        let rest = smoother.advance(at: 0.08)
        XCTAssertEqual(first + rest, 10, accuracy: 1e-12)
        XCTAssertFalse(smoother.isActive)
        XCTAssertEqual(smoother.advance(at: 0.09), 0)
    }

    func testFractionalDistanceAndNegativeDirectionArePreserved() {
        for distance in [0.125, -0.125, 3.75, -3.75] {
            var smoother = ScrollSmoother()
            XCTAssertTrue(smoother.enqueue(delta: distance, at: 0))
            var total = 0.0
            for time in [0.003, 0.01, 0.019, 0.033, 0.056, 0.08] {
                let output = smoother.advance(at: time)
                XCTAssertEqual(output.sign, distance.sign)
                total += output
            }
            XCTAssertEqual(total, distance, accuracy: 1e-14)
            XCTAssertFalse(smoother.isActive)
        }
    }

    func testOutputDependsOnElapsedTimeRatherThanNumberOfFrames() {
        var regular = ScrollSmoother()
        var irregular = ScrollSmoother()
        XCTAssertTrue(regular.enqueue(delta: 37.25, at: 1))
        XCTAssertTrue(irregular.enqueue(delta: 37.25, at: 1))
        var regularTotal = 0.0
        for time in [1.002, 1.005, 1.011, 1.02, 1.037] {
            regularTotal += regular.advance(at: time)
        }
        XCTAssertEqual(regularTotal, irregular.advance(at: 1.037), accuracy: 1e-11)
        XCTAssertEqual(regular.advance(at: 1.08), irregular.advance(at: 1.08), accuracy: 1e-11)
        XCTAssertFalse(regular.isActive)
        XCTAssertFalse(irregular.isActive)
    }

    func testInputBetweenFramesDoesNotLoseOrBackdateDistance() {
        var smoother = ScrollSmoother()
        XCTAssertTrue(smoother.enqueue(delta: 10, at: 0))
        XCTAssertTrue(smoother.enqueue(delta: 10, at: 0.01))
        let first = smoother.advance(at: 0.01)
        XCTAssertEqual(first, 2.6424111765711533, accuracy: 1e-12)
        XCTAssertEqual(first + smoother.advance(at: 0.1), 20, accuracy: 1e-12)
        XCTAssertFalse(smoother.isActive)
    }

    func testTailSettlesAtDeadlineRegardlessOfClockEpoch() {
        for epoch in [0, 1.08, 10.17, 1_000_000.13] {
            var smoother = ScrollSmoother()
            XCTAssertTrue(smoother.enqueue(delta: 0.25, at: epoch))
            XCTAssertEqual(smoother.advance(at: epoch + 0.08), 0.25)
            XCTAssertFalse(smoother.isActive)
        }
    }

    func testSustainedRapidInputKeepsMovingAndFinishesAfterLastInput() {
        var smoother = ScrollSmoother()
        var total = 0.0
        for index in 0..<200 {
            let time = Double(index) * 0.005
            XCTAssertTrue(smoother.enqueue(delta: 10, at: time))
            total += smoother.advance(at: time)
        }
        total += smoother.advance(at: 1)
        // Restarting acceleration for every input would leave over 100 pixels behind.
        XCTAssertGreaterThan(total, 1940)
        XCTAssertLessThan(total, 2000)
        total += smoother.advance(at: 1.08)
        XCTAssertEqual(total, 2000, accuracy: 1e-9)
        XCTAssertFalse(smoother.isActive)
    }

    func testDirectionChangeDiscardsAllUndeliveredOldMotion() {
        var smoother = ScrollSmoother()
        XCTAssertTrue(smoother.enqueue(delta: 10, at: 0))
        XCTAssertTrue(smoother.enqueue(delta: 10, at: 0.005))
        // Both generated-but-undelivered output and the remaining old tail cancel.
        XCTAssertTrue(smoother.enqueue(delta: -3.5, at: 0.01))
        XCTAssertEqual(smoother.advance(at: 0.01), 0)
        let first = smoother.advance(at: 0.02)
        XCTAssertLessThan(first, 0)
        let rest = smoother.advance(at: 0.1)
        XCTAssertEqual(first + rest, -3.5, accuracy: 1e-12)
        XCTAssertFalse(smoother.isActive)
    }

    func testDuplicateTimesCombineWithoutProducingPrematureMotion() {
        var smoother = ScrollSmoother()
        XCTAssertTrue(smoother.enqueue(delta: 0.5, at: 4))
        XCTAssertTrue(smoother.enqueue(delta: 0.75, at: 4))
        XCTAssertEqual(smoother.advance(at: 4), 0)
        XCTAssertEqual(smoother.advance(at: 4.09), 1.25)
        XCTAssertFalse(smoother.isActive)
    }

    func testResetDiscardsMotionAndAllowsANewGesture() {
        var smoother = ScrollSmoother()
        XCTAssertTrue(smoother.enqueue(delta: 10, at: 0))
        smoother.reset()
        XCTAssertFalse(smoother.isActive)
        XCTAssertEqual(smoother.advance(at: 0.02), 0)
        XCTAssertTrue(smoother.enqueue(delta: -0.25, at: 0.03))
        XCTAssertEqual(smoother.advance(at: 0.12), -0.25)
    }

    func testLongPauseDropsStaleTailRatherThanJumpingAfterWake() {
        var smoother = ScrollSmoother()
        XCTAssertTrue(smoother.enqueue(delta: 10, at: 0))
        XCTAssertGreaterThan(smoother.advance(at: 0.01), 0)
        XCTAssertEqual(smoother.advance(at: 2), 0)
        XCTAssertFalse(smoother.isActive)
        XCTAssertTrue(smoother.enqueue(delta: 4, at: 3))
        XCTAssertTrue(smoother.enqueue(delta: 2, at: 4))
        XCTAssertEqual(smoother.advance(at: 4.09), 2)
    }

    func testBackwardTimeStartsANewEpoch() {
        var smoother = ScrollSmoother()
        XCTAssertTrue(smoother.enqueue(delta: 10, at: 2))
        XCTAssertEqual(smoother.advance(at: 1), 0)
        XCTAssertFalse(smoother.isActive)
        XCTAssertTrue(smoother.enqueue(delta: 2, at: 1))
        XCTAssertTrue(smoother.enqueue(delta: 3, at: 0))
        XCTAssertEqual(smoother.advance(at: 0.09), 3)
    }

    func testMalformedInputCannotPoisonOrCancelValidMotion() {
        var smoother = ScrollSmoother()
        XCTAssertTrue(smoother.enqueue(delta: 5, at: 0))
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(smoother.enqueue(delta: value, at: 0.01))
            XCTAssertFalse(smoother.enqueue(delta: -1, at: value))
            XCTAssertEqual(smoother.advance(at: value), 0)
        }
        XCTAssertFalse(smoother.enqueue(delta: 0, at: 0.03))
        XCTAssertFalse(smoother.enqueue(delta: -1_000_000_001, at: 0.01))
        XCTAssertEqual(smoother.advance(at: 0.09), 5)
        XCTAssertFalse(smoother.isActive)
    }

    func testDistanceLimitRejectsAccumulationWithoutLosingAcceptedDistance() {
        var smoother = ScrollSmoother()
        XCTAssertTrue(smoother.enqueue(delta: 600_000_000, at: 0))
        XCTAssertFalse(smoother.enqueue(delta: 500_000_000, at: 0.01))
        XCTAssertTrue(smoother.enqueue(delta: 400_000_000, at: 0))
        XCTAssertFalse(smoother.enqueue(delta: 1, at: 0.02))
        XCTAssertEqual(smoother.advance(at: 0.09), 1_000_000_000)
        XCTAssertFalse(smoother.isActive)
    }

    func testPositiveResponseOverridesAndInvalidConfigurationStayFinite() {
        for response in [Double.leastNonzeroMagnitude, 0.04, 0.08] {
            var smoother = ScrollSmoother(responseTime: response)
            XCTAssertTrue(smoother.enqueue(delta: 1_000_000_000, at: 0))
            let first = smoother.advance(at: response / 2)
            let second = smoother.advance(at: response)
            XCTAssertTrue(first.isFinite)
            XCTAssertTrue(second.isFinite)
            XCTAssertEqual(first + second, 1_000_000_000, accuracy: 1e-6)
            XCTAssertFalse(smoother.isActive)
        }
        for invalid in [0, -1, Double.nan, .infinity] {
            var smoother = ScrollSmoother(responseTime: invalid, staleInterval: invalid)
            XCTAssertTrue(smoother.enqueue(delta: 0.5, at: 0))
            XCTAssertEqual(smoother.advance(at: 0.08), 0.5)
            XCTAssertFalse(smoother.isActive)
        }
    }
}
