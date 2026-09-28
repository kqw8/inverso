import CoreGraphics
import InversoKit
import XCTest

final class ScrollStressTests: XCTestCase {
    // Catches state leaking between devices, losing sub-line deltas, reversing
    // momentum, or changing metadata/other axes while the same events recur.
    // These events remain in memory: no event tap or global event posting.
    func testMixedEventsPreserveMetadataAndAllOtherAxesAcross120000Transforms() throws {
        let cases: [(name: String, vertical: Axis, field: CGEventField?, value: Int64, reverse: Bool)] = [
            ("wheel up", Axis(3, 17, 1.5), nil, 0, true),
            ("wheel down", Axis(-2, -11, -0.75), nil, 0, true),
            ("continuous wheel", Axis(1, 9, 0.5), .scrollWheelEventIsContinuous, 1, true),
            ("point-only sub-line", Axis(0, 1, 0), nil, 0, true),
            ("fixed-only sub-line", Axis(0, 0, 0.125), nil, 0, true),
            ("gesture", Axis(2, 12, 1), .scrollWheelEventScrollPhase, 2, false),
            ("momentum", Axis(-1, -8, -0.5), .scrollWheelEventMomentumPhase, 1, false),
            ("scroll count", Axis(1, 5, 0.25), .scrollWheelEventScrollCount, 2, false),
            ("synthetic", Axis(1, 5, 0.25), .eventSourceUserData, ScrollTransform.syntheticMarker, false),
            ("horizontal-only", Axis(0, 0, 0), nil, 0, false),
            ("third-axis-only", Axis(0, 0, 0), nil, 0, false),
            ("non-scroll", Axis(2, 10, 1), nil, 0, false),
        ]
        let events = try cases.enumerated().map { index, item -> CGEvent in
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                             wheelCount: 3, wheel1: 0, wheel2: 0, wheel3: 0))
            setAxis(item.vertical, on: event, fields: Self.verticalFields)
            setAxis(index == 10 ? Axis(0, 0, 0) : Axis(-3, -21, -2.25),
                    on: event, fields: Self.horizontalFields)
            setAxis(index == 9 ? Axis(0, 0, 0) : Axis(2, 13, 0.75),
                    on: event, fields: Self.thirdFields)
            event.timestamp = 7_000_000_000 + UInt64(index) * 123_456
            event.location = CGPoint(x: 100 + index, y: 200 - index)
            event.flags = index.isMultiple(of: 2) ? [.maskShift, .maskControl] : [.maskAlternate]
            // Initialize source data once; macOS may retain the first explicit
            // source-data value when this field is assigned repeatedly.
            if item.field != .eventSourceUserData {
                event.setIntegerValueField(.eventSourceUserData, value: 101 + Int64(index))
            }
            if let field = item.field { event.setIntegerValueField(field, value: item.value) }
            if index == 11 { event.type = .mouseMoved }
            return event
        }
        let originals = events.map(Snapshot.init)

        for round in 0..<10_000 {
            // Alternating direction/device/gesture every call must not carry state.
            for (index, event) in events.enumerated() {
                let fixture = cases[index]
                let changed = ScrollTransform.reverseMouseWheelEvent(event)
                var expected = originals[index]
                if fixture.reverse && round.isMultiple(of: 2) {
                    expected.vertical = fixture.vertical.negated
                }
                guard changed == fixture.reverse, Snapshot(event) == expected else {
                    XCTFail("\(fixture.name) changed fields or classification on round \(round)")
                    return
                }
            }
        }
    }

    private struct Axis: Equatable {
        var line: Int64
        var point: Double
        var fixed: Double

        init(_ line: Int64, _ point: Double, _ fixed: Double) {
            self.line = line
            self.point = point
            self.fixed = fixed
        }

        init(_ event: CGEvent, fields: [CGEventField]) {
            self.init(event.getIntegerValueField(fields[0]), event.getDoubleValueField(fields[1]),
                      event.getDoubleValueField(fields[2]))
        }

        var negated: Axis { Axis(-line, -point, -fixed) }
    }

    private struct Snapshot: Equatable {
        var vertical: Axis
        let horizontal: Axis
        let third: Axis
        let type: CGEventType
        let timestamp: UInt64
        let location: CGPoint
        let flags: CGEventFlags
        let metadata: [Int64]

        init(_ event: CGEvent) {
            vertical = Axis(event, fields: ScrollStressTests.verticalFields)
            horizontal = Axis(event, fields: ScrollStressTests.horizontalFields)
            third = Axis(event, fields: ScrollStressTests.thirdFields)
            type = event.type
            timestamp = event.timestamp
            location = event.location
            flags = event.flags
            metadata = ScrollStressTests.metadataFields.map(event.getIntegerValueField)
        }
    }

    private func setAxis(_ axis: Axis, on event: CGEvent, fields: [CGEventField]) {
        event.setIntegerValueField(fields[0], value: axis.line)
        event.setDoubleValueField(fields[1], value: axis.point)
        event.setDoubleValueField(fields[2], value: axis.fixed)
    }

    private static let verticalFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1,
    ]
    private static let horizontalFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2,
    ]
    private static let thirdFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis3, .scrollWheelEventPointDeltaAxis3, .scrollWheelEventFixedPtDeltaAxis3,
    ]
    private static let metadataFields: [CGEventField] = [
        .eventSourceUserData, .eventSourceUnixProcessID, .eventSourceUserID,
        .eventSourceGroupID, .eventSourceStateID, .scrollWheelEventIsContinuous,
        .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase, .scrollWheelEventScrollCount,
    ]
}
