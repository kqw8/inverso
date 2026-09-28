@testable import InversoKit
import CoreGraphics
import XCTest

final class ScrollEventProcessorTests: XCTestCase {
    func testDiscreteWheelBecomesFiniteReversedPixelStream() throws {
        let harness = Harness()
        let event = try wheel(point: 10, line: 1, fixed: 1)
        event.location = CGPoint(x: 123, y: 456)
        XCTAssertNil(harness.processor.handle(type: .scrollWheel, event: event))
        XCTAssertTrue(harness.driver.isRunning)
        XCTAssertTrue(harness.output.isEmpty)
        harness.drain()
        XCTAssertGreaterThan(harness.output.count, 1)
        XCTAssertEqual(harness.pixels, -40)
        XCTAssertFalse(harness.driver.isRunning)
        for output in harness.output {
            XCTAssertTrue(ScrollTransform.isSynthetic(output))
            XCTAssertEqual(output.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
            XCTAssertEqual(output.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
            XCTAssertEqual(output.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
            XCTAssertEqual(output.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 0)
            XCTAssertEqual(output.getIntegerValueField(.scrollWheelEventPointDeltaAxis3), 0)
            XCTAssertEqual(output.location, event.location)
            XCTAssertEqual(output.flags, event.flags)
        }
    }

    func testWheelCallbackCreatesNoEvents() throws {
        // Event creation can call WindowServer, which is waiting for this callback.
        let harness = Harness()
        XCTAssertNil(harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40)))
        XCTAssertEqual(harness.eventsCreated, 0)
        harness.drain()
        XCTAssertEqual(harness.pixels, -40)
    }

    func testOnePixelIsNotLostAcrossManyFractionalFrames() throws {
        let harness = Harness()
        XCTAssertNil(harness.processor.handle(type: .scrollWheel, event: try wheel(point: 1)))
        for step in 1...80 { harness.fire(at: Double(step) / 1_000) }
        XCTAssertEqual(harness.pixels, -1)
        XCTAssertFalse(harness.driver.isRunning)
    }

    func testFractionalLineDistanceUsesApplicationUnitsInsteadOfSourcePixels() throws {
        let harness = Harness()
        let event = try wheel(point: 2, fixed: 0.25)
        XCTAssertNil(harness.processor.handle(type: .scrollWheel, event: event))
        harness.drain()
        XCTAssertEqual(harness.pixels, -10)
        _ = harness.processor.handle(type: .scrollWheel,
                                     event: try wheel(point: 0, fixed: 0.25))
        harness.drain()
        XCTAssertEqual(harness.pixels, -20)
    }

    func testIntegerLineDistanceIsUsedWhenFixedPointDistanceIsAbsent() throws {
        let harness = Harness()
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 20, line: 2))
        harness.drain()
        XCTAssertEqual(harness.pixels, -80)
    }

    func testAcceleratedFractionalLinesTakePrecedenceOverRoundedLineCount() throws {
        let cases: [(Int64, Int32, Double, Int64)] = [(15, 1, 1.5, -60), (-12, -1, -1.25, 50)]
        for (point, line, fixed, expected) in cases {
            let harness = Harness()
            _ = harness.processor.handle(type: .scrollWheel,
                                          event: try wheel(point: point, line: line, fixed: fixed))
            harness.drain()
            XCTAssertEqual(harness.pixels, expected)
        }
    }

    func testPointOnlyDistanceRemainsInPixels() throws {
        let harness = Harness()
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 7))
        harness.drain()
        XCTAssertEqual(harness.pixels, -7)
    }

    func testInitialSpeedMultiplierScalesDiscreteWheelDistance() throws {
        for (multiplier, expected): (Double, Int64) in [(0.25, -10), (1.5, -60), (4, -160)] {
            let harness = Harness(speedMultiplier: multiplier)
            _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 10, line: 1, fixed: 1))
            harness.drain()
            XCTAssertEqual(harness.pixels, expected)
        }
    }

    func testInvalidInitialSpeedUsesDefaultDistance() throws {
        for invalid in [Double.nan, .infinity, -.infinity, 0, 0.249, 4.001] {
            let harness = Harness(speedMultiplier: invalid)
            _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 10, line: 1, fixed: 1))
            harness.drain()
            XCTAssertEqual(harness.pixels, -40)
        }
    }

    func testChangedSpeedCancelsPendingMotionAndAppliesToNextInput() throws {
        let harness = Harness()
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 10, line: 1, fixed: 1))
        harness.processor.setScrollSpeed(1.5)
        XCTAssertFalse(harness.driver.isRunning)
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 10, line: 1, fixed: 1))
        harness.drain()
        XCTAssertEqual(harness.pixels, -60)
    }

    func testUnchangedSpeedDoesNotCancelPendingMotion() throws {
        let harness = Harness(speedMultiplier: 1.5)
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 10, line: 1, fixed: 1))
        harness.processor.setScrollSpeed(1.5)
        harness.drain()
        XCTAssertEqual(harness.pixels, -60)
    }

    func testInvalidSpeedChangePreservesPendingMotionAndPreviousGain() throws {
        for invalid in [Double.nan, .infinity, -.infinity, 0, 0.249, 4.001] {
            let harness = Harness(speedMultiplier: 1.5)
            _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 10, line: 1, fixed: 1))
            harness.processor.setScrollSpeed(invalid)
            harness.drain()
            XCTAssertEqual(harness.pixels, -60)
            _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 10, line: 1, fixed: 1))
            harness.drain()
            XCTAssertEqual(harness.pixels, -120)
        }
    }

    func testFractionalPixelsCarryAcrossUninterruptedGestures() throws {
        let harness = Harness()
        for _ in 0..<4 {
            let event = try wheel(point: 0, fixed: 1.0 / 32)
            XCTAssertNil(harness.processor.handle(type: .scrollWheel, event: event))
            harness.drain()
        }
        XCTAssertEqual(harness.pixels, -5)
    }

    func testOppositeDirectionBeforeFrameHasNoOldDirectionOutput() throws {
        let harness = Harness()
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40))
        harness.time = 0.004
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: -30))
        harness.drain()
        XCTAssertEqual(harness.pixels, 30)
        XCTAssertTrue(harness.output.allSatisfy { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) > 0 })
    }

    func testOwnSyntheticFramesDoNotCancelOrReenterSmoothing() throws {
        let harness = Harness()
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40))
        harness.fire(at: 0.02)
        let output = try XCTUnwrap(harness.output.first)
        let before = ScrollTransform.verticalSample(from: output)
        XCTAssertTrue(harness.processor.handle(type: .scrollWheel, event: output)?.takeUnretainedValue() === output)
        XCTAssertEqual(ScrollTransform.verticalSample(from: output), before)
        XCTAssertTrue(harness.driver.isRunning)
        harness.drain()
        XCTAssertEqual(harness.pixels, -40)
    }

    func testContinuousWheelPassesThroughWithDirectReversal() throws {
        let harness = Harness(speedMultiplier: 1.5)
        let event = try wheel(point: 17)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        XCTAssertTrue(harness.processor.handle(type: .scrollWheel, event: event)?.takeUnretainedValue() === event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -17)
        XCTAssertFalse(harness.driver.isRunning)
        XCTAssertTrue(harness.output.isEmpty)
    }

    func testNativeGestureCancelsPendingMotionAndIsUnchanged() throws {
        let harness = Harness(speedMultiplier: 1.5)
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40))
        let event = try wheel(point: 25)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        XCTAssertTrue(harness.processor.handle(type: .scrollWheel, event: event)?.takeUnretainedValue() === event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 25)
        XCTAssertFalse(harness.driver.isRunning)
        harness.fire(at: 0.1)
        XCTAssertTrue(harness.output.isEmpty)
    }

    func testModifiedAndMixedAxisEventsRemainDirect() throws {
        for mode in 0..<3 {
            let harness = Harness(speedMultiplier: 1.5)
            _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40))
            let event = try wheel(point: 20)
            if mode == 0 { event.flags = .maskControl }
            if mode == 1 { event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 7) }
            if mode == 2 { event.setIntegerValueField(.scrollWheelEventPointDeltaAxis3, value: 9) }
            XCTAssertNotNil(harness.processor.handle(type: .scrollWheel, event: event))
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -20)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), mode == 1 ? 7 : 0)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis3), mode == 2 ? 9 : 0)
            XCTAssertFalse(harness.driver.isRunning)
        }
    }

    func testPointerButtonAndModifierEventsNeverDiscardAConsumedNotch() throws {
        // A consumed notch must always be delivered: moving, clicking or pressing
        // the wheel while scrolling is common, especially with a sensitive mouse.
        for type: CGEventType in [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                  .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
                                  .leftMouseDragged, .rightMouseDragged,
                                  .otherMouseDragged, .flagsChanged] {
            let harness = Harness()
            _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40))
            let event = try XCTUnwrap(CGEvent(source: nil))
            event.type = type
            event.location = CGPoint(x: 900, y: 900)
            XCTAssertTrue(harness.processor.handle(type: type, event: event)?.takeUnretainedValue() === event)
            XCTAssertTrue(harness.driver.isRunning, "\(type)")
            harness.drain()
            XCTAssertEqual(harness.pixels, -40, "\(type)")
        }
    }

    func testNotchesAtAnotherLocationOrTargetKeepAllDistance() throws {
        for change in ["location", "target"] {
            let harness = Harness()
            let first = try wheel(point: 40)
            first.location = CGPoint(x: 100, y: 100)
            first.setIntegerValueField(.eventTargetUnixProcessID, value: 42)
            _ = harness.processor.handle(type: .scrollWheel, event: first)
            harness.time = 0.004
            let second = try wheel(point: 40)
            second.location = change == "location" ? CGPoint(x: 300, y: 300) : first.location
            second.setIntegerValueField(.eventTargetUnixProcessID, value: change == "target" ? 43 : 42)
            _ = harness.processor.handle(type: .scrollWheel, event: second)
            harness.drain()
            XCTAssertEqual(harness.pixels, -80, change)
        }
    }

    func testFramesCarryTheLatestWheelLocationAndFlags() throws {
        let harness = Harness()
        let first = try wheel(point: 40)
        first.location = CGPoint(x: 100, y: 100)
        _ = harness.processor.handle(type: .scrollWheel, event: first)
        harness.time = 0.004
        let second = try wheel(point: 40)
        second.location = CGPoint(x: 102, y: 100)
        second.flags = .maskNonCoalesced
        _ = harness.processor.handle(type: .scrollWheel, event: second)
        harness.drain()
        XCTAssertFalse(harness.output.isEmpty)
        for output in harness.output {
            XCTAssertEqual(output.location, second.location)
            XCTAssertEqual(output.flags, second.flags)
        }
    }

    func testNonContextFlagsDoNotDiscardAcceptedDistance() throws {
        let harness = Harness()
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40))
        harness.time = 0.004
        let second = try wheel(point: 40)
        second.flags = .maskNonCoalesced
        _ = harness.processor.handle(type: .scrollWheel, event: second)
        harness.drain()
        XCTAssertEqual(harness.pixels, -80)
        XCTAssertTrue(harness.output.allSatisfy { $0.flags == .maskNonCoalesced })
    }

    func testLongSchedulingGapDropsTailInsteadOfJumpingAfterWake() throws {
        let harness = Harness()
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40))
        harness.fire(at: 2)
        XCTAssertTrue(harness.output.isEmpty)
        XCTAssertFalse(harness.driver.isRunning)
    }

    func testDriverFailureFallsBackBeforeSuppressingInput() throws {
        let harness = Harness()
        harness.driver.canStart = false
        let event = try wheel(point: 40)
        XCTAssertNotNil(harness.processor.handle(type: .scrollWheel, event: event))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -40)
        XCTAssertFalse(harness.driver.isRunning)
        XCTAssertTrue(harness.output.isEmpty)
    }

    func testFrameAllocationFailureStopsWithoutPosting() throws {
        let harness = Harness()
        XCTAssertNil(harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40)))
        harness.failAllocation = true
        harness.drain()
        XCTAssertTrue(harness.output.isEmpty)
        XCTAssertFalse(harness.driver.isRunning)
    }

    func testExplicitCancelStopsAndAllowsNextGesture() throws {
        let harness = Harness()
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: 40))
        harness.processor.cancel()
        XCTAssertFalse(harness.driver.isRunning)
        _ = harness.processor.handle(type: .scrollWheel, event: try wheel(point: -20))
        harness.drain()
        XCTAssertEqual(harness.pixels, 20)
    }

    // Point-only fixtures exercise output/cancellation independently of line conversion.
    // Conversion tests specify independent line, fixed-point, and point fields explicitly.
    private func wheel(point: Int64, line: Int32 = 0, fixed: Double = 0,
                       source: CGEventSource? = nil) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: source, units: .line,
                                         wheelCount: 3, wheel1: line, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: point)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed)
        // Synthetic construction otherwise inherits the user's current modifiers.
        event.flags = []
        return event
    }

    private final class Harness {
        static let events = PixelEventFactory()
        let driver = Driver()
        var time = 0.0
        var output: [CGEvent] = []
        var failAllocation = false
        var eventsCreated = 0
        let speedMultiplier: Double

        init(speedMultiplier: Double = 1) { self.speedMultiplier = speedMultiplier }

        lazy var processor = ScrollEventProcessor(driver: driver, now: { [unowned self] in time },
            makeEvent: { [unowned self] pixels in
                eventsCreated += 1
                return failAllocation ? nil : Harness.events?.make(pixels: pixels)
            }, post: { [unowned self] in output.append($0) }, speedMultiplier: speedMultiplier)

        var pixels: Int64 { output.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) } }

        func fire(at time: Double) { self.time = time; driver.frame?() }

        func drain() {
            let start = time
            for tick in 1...12 { fire(at: start + Double(tick) / 120) }
        }
    }

    private final class Driver: SmoothingFrameDriving {
        var frame: (() -> Void)?
        var canStart = true
        var isRunning: Bool { frame != nil }
        func start(_ onFrame: @escaping () -> Void) -> Bool {
            guard canStart else { return false }
            frame = onFrame
            return true
        }
        func stop() { frame = nil }
    }
}
