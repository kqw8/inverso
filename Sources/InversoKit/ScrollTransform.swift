import CoreGraphics
import Foundation

public struct ScrollSample: Equatable {
    public var delta: Int64
    public var pointDelta: Double
    public var fixedPointDelta: Double

    public init(delta: Int64, pointDelta: Double, fixedPointDelta: Double) {
        self.delta = delta
        self.pointDelta = pointDelta
        self.fixedPointDelta = fixedPointDelta
    }

    public var hasValue: Bool {
        delta != 0 || pointDelta != 0.0 || fixedPointDelta != 0.0
    }
}

public enum ScrollTransform {
    public static let syntheticMarker: Int64 = 0x00494E56524552534F

    public static func verticalSample(from event: CGEvent) -> ScrollSample {
        ScrollSample(
            delta: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            pointDelta: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            fixedPointDelta: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        )
    }

    public static func horizontalSample(from event: CGEvent) -> ScrollSample {
        ScrollSample(
            delta: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointDelta: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            fixedPointDelta: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
    }

    public static func hasHorizontalDelta(_ event: CGEvent) -> Bool {
        horizontalSample(from: event).hasValue
    }

    public static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }

    public static func isLikelyTrackpad(_ event: CGEvent) -> Bool {
        // Do not use isContinuous as a device identifier: mouse drivers can
        // produce pixel-based wheel events too. This remains a heuristic.
        event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
            || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            || event.getIntegerValueField(.scrollWheelEventScrollCount) != 0
    }

    public static func reverseVerticalFields(on event: CGEvent) {
        // Read everything first: writing the line delta can also change the
        // point and fixed-point fields inside Core Graphics.
        let sample = verticalSample(from: event)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -sample.delta)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -sample.pointDelta)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -sample.fixedPointDelta)
    }

    /// Mutates only eligible vertical wheel deltas; returns whether they changed.
    @discardableResult
    public static func reverseMouseWheelEvent(_ event: CGEvent) -> Bool {
        guard event.type == .scrollWheel,
              !isSynthetic(event),
              !isLikelyTrackpad(event),
              verticalSample(from: event).hasValue else {
            return false
        }
        reverseVerticalFields(on: event)
        return true
    }
}
