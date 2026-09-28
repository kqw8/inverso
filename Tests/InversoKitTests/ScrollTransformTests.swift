import CoreGraphics
import InversoKit
import XCTest

final class ScrollTransformTests: XCTestCase {
    func testReverseVerticalFieldsNegatesOnlyVerticalFields() throws {
        let event = try makeEvent(delta: 4, point: 8.0, fixed: 2.0, horizontalDelta: 3, horizontalPoint: 6.0)
        ScrollTransform.reverseVerticalFields(on: event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -4)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), -8.0)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -2.0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 3)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2), 6.0)
    }

    func testTrackpadHeuristicUsesPhasesAndScrollCount() throws {
        for field: CGEventField in [.scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase,
                                    .scrollWheelEventScrollCount] {
            let event = try makeEvent(delta: 1, point: 9, fixed: 1.25)
            let before = ScrollTransform.verticalSample(from: event)
            event.setIntegerValueField(field, value: 2)
            XCTAssertFalse(ScrollTransform.reverseMouseWheelEvent(event), "\(field)")
            XCTAssertEqual(ScrollTransform.verticalSample(from: event), before)
        }
    }

    func testContinuousWheelWithoutGesturePhasesStillReverses() throws {
        // Some mouse drivers set isContinuous. It alone must not exclude a wheel.
        let event = try makeEvent(delta: -2, point: -7, fixed: -1.5,
                                  horizontalDelta: 3, horizontalPoint: 11)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 2.25)
        event.flags = [.maskShift, .maskControl]
        event.setIntegerValueField(.eventSourceUserData, value: 1234)
        let horizontal = ScrollTransform.horizontalSample(from: event)
        XCTAssertTrue(ScrollTransform.reverseMouseWheelEvent(event))
        XCTAssertEqual(ScrollTransform.verticalSample(from: event),
                       ScrollSample(delta: 2, pointDelta: 7, fixedPointDelta: 1.5))
        XCTAssertEqual(ScrollTransform.horizontalSample(from: event), horizontal)
        XCTAssertEqual(event.flags, [.maskShift, .maskControl])
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 1234)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
    }

    func testSubLineDeltaIsReversedEvenWhenLineDeltaIsZero() throws {
        let event = try makeEvent(point: 1, fixed: 0.125)
        XCTAssertTrue(ScrollTransform.reverseMouseWheelEvent(event))
        XCTAssertEqual(ScrollTransform.verticalSample(from: event),
                       ScrollSample(delta: 0, pointDelta: -1, fixedPointDelta: -0.125))
    }

    func testHorizontalOnlyAndZeroEventsAreUnchanged() throws {
        for horizontal: Int64 in [0, 3] {
            let event = try makeEvent(horizontalDelta: horizontal, horizontalPoint: Double(horizontal) * 5)
            let before = ScrollTransform.horizontalSample(from: event)
            XCTAssertFalse(ScrollTransform.reverseMouseWheelEvent(event))
            XCTAssertEqual(ScrollTransform.horizontalSample(from: event), before)
            XCTAssertFalse(ScrollTransform.verticalSample(from: event).hasValue)
        }
    }

    func testNonScrollEventsAreIgnored() throws {
        let event = try makeEvent(delta: 2, point: 7, fixed: 1.5)
        event.type = .mouseMoved
        XCTAssertFalse(ScrollTransform.reverseMouseWheelEvent(event))
    }

    private func makeEvent(
        delta: Int64 = 0,
        point: Double = 0.0,
        fixed: Double = 0.0,
        horizontalDelta: Int64 = 0,
        horizontalPoint: Double = 0.0
    ) throws -> CGEvent {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else {
            throw NSError(domain: "InversoTests", code: 1)
        }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: delta)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: point)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: horizontalDelta)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: horizontalPoint)
        return event
    }
}
