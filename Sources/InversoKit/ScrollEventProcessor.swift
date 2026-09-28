import CoreGraphics
import Foundation

/// The entire pipeline, including its timer and output, belongs to the event
/// thread. The injectable initializer never supplies a real event-posting sink.
final class ScrollEventProcessor {
    private let driver: SmoothingFrameDriving
    private let now: () -> Double
    private let makeEvent: (Int32) -> CGEvent?
    private let post: (CGEvent) -> Void
    private var speedMultiplier = 1.0
    private var smoother = ScrollSmoother()
    private var fractionalPixels = 0.0
    private var direction: FloatingPointSign?
    private var lastActivity: Double?
    private var location = CGPoint.zero
    private var flags = CGEventFlags()
    private var targetProcess: Int64 = 0
    private var latestWheelTimestamp: CGEventTimestamp = 0
    private static let contextModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate,
                                                        .maskCommand, .maskSecondaryFn, .maskAlphaShift]

    init(driver: SmoothingFrameDriving, now: @escaping () -> Double,
         makeEvent: @escaping (Int32) -> CGEvent?, post: @escaping (CGEvent) -> Void,
         speedMultiplier: Double = 1) {
        self.driver = driver
        self.now = now
        self.makeEvent = makeEvent
        self.post = post
        if Self.isValidSpeed(speedMultiplier) { self.speedMultiplier = speedMultiplier }
    }

    /// Nil when no event source is available; the caller keeps direct reversal.
    static func production(speedMultiplier: Double = 1) -> ScrollEventProcessor? {
        guard let events = PixelEventFactory() else { return nil }
        // Unlike uptime, this clock advances during sleep so stale tails expire.
        let origin = ContinuousClock.now
        return ScrollEventProcessor(driver: RunLoopSmoothingDriver(),
            now: {
                let elapsed = origin.duration(to: .now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            },
            makeEvent: { events.make(pixels: $0) },
            post: { $0.post(tap: .cgSessionEventTap) }, speedMultiplier: speedMultiplier)
    }

    /// Apply on the owning event thread. Invalid or unchanged settings preserve motion.
    func setScrollSpeed(_ multiplier: Double) {
        guard Self.isValidSpeed(multiplier), multiplier != speedMultiplier else { return }
        cancel()
        speedMultiplier = multiplier
    }

    private static func isValidSpeed(_ multiplier: Double) -> Bool {
        multiplier.isFinite && (0.25...4).contains(multiplier)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Our frames must neither be reversed again nor cancel their own tail.
        if ScrollTransform.isSynthetic(event) { return Unmanaged.passUnretained(event) }
        guard type == .scrollWheel else {
            // Passive and active tap sources need not dispatch in timestamp order.
            if event.timestamp > 0 && event.timestamp < latestWheelTimestamp {
                return Unmanaged.passUnretained(event)
            }
            let observedTarget = event.getIntegerValueField(.eventTargetUnixProcessID)
            if type == .mouseMoved && direction != nil && isNearAnchor(event.location)
                && event.flags.intersection(Self.contextModifiers) == flags.intersection(Self.contextModifiers)
                && (observedTarget == 0 || targetProcess == 0 || observedTarget == targetProcess) {
                // Tolerate tiny hand jitter, but never move the gesture's anchor.
                if observedTarget != 0 { targetProcess = observedTarget }
                return Unmanaged.passUnretained(event)
            }
            cancel()
            return Unmanaged.passUnretained(event)
        }
        guard isEligible(event) else { return direct(event) }

        let time = now()
        let pixels = -pixelDistance(event) * speedMultiplier
        guard time.isFinite, pixels.isFinite, pixels != 0,
              abs(pixels) <= ScrollSmoother.maximumDistance else { return direct(event) }

        if let previous = lastActivity, time < previous || time - previous >= 0.5 { cancel() }
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        if direction != nil && (!isNearAnchor(event.location)
            || event.flags.intersection(Self.contextModifiers) != flags.intersection(Self.contextModifiers)
            || (target != 0 && targetProcess != 0 && target != targetProcess)) {
            cancel()
        }
        if let direction, direction != pixels.sign {
            // Discard the old direction before integrating or emitting anything.
            cancel()
        }

        // Start the driver before consuming the user's physical input. Events are
        // created only by frames: this callback must never wait for WindowServer.
        guard driver.start({ [weak self] in self?.frame() }),
              smoother.enqueue(delta: pixels, at: time) else { return direct(event) }

        if direction == nil { location = event.location }
        direction = pixels.sign
        lastActivity = time
        flags = event.flags
        // A temporarily unavailable target must not erase the last known context.
        if target != 0 { targetProcess = target }
        latestWheelTimestamp = event.timestamp
        return nil
    }

    func cancel() {
        smoother.reset()
        fractionalPixels = 0
        direction = nil
        lastActivity = nil
        targetProcess = 0
        latestWheelTimestamp = 0
        driver.stop()
    }

    private func direct(_ event: CGEvent) -> Unmanaged<CGEvent> {
        cancel()
        ScrollTransform.reverseMouseWheelEvent(event)
        return Unmanaged.passUnretained(event)
    }

    private func isEligible(_ event: CGEvent) -> Bool {
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        return event.type == .scrollWheel && !ScrollTransform.isLikelyTrackpad(event)
            && event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
            && event.flags.intersection(modifiers).isEmpty
            && ScrollTransform.verticalSample(from: event).hasValue
            && !ScrollTransform.hasHorizontalDelta(event)
            && event.getIntegerValueField(.scrollWheelEventDeltaAxis3) == 0
            && event.getIntegerValueField(.scrollWheelEventPointDeltaAxis3) == 0
            && event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3) == 0
    }

    private func pixelDistance(_ event: CGEvent) -> Double {
        let sample = ScrollTransform.verticalSample(from: event)
        // Discrete AppKit deltas are lines; Chromium maps each line to 40 pixels.
        // CG's point field uses a different source scale (normally 10 pixels/line),
        // so preserving it while changing to precise events shortens the scroll.
        if sample.fixedPointDelta != 0 { return sample.fixedPointDelta * 40 }
        if sample.delta != 0 { return Double(sample.delta) * 40 }
        // Some drivers provide only point distance, which is already in pixels.
        return sample.pointDelta
    }

    private func isNearAnchor(_ point: CGPoint) -> Bool {
        let dx = point.x - location.x
        let dy = point.y - location.y
        return dx * dx + dy * dy <= 9 // Three display-coordinate units from origin.
    }

    private func frame() {
        let time = now()
        guard time.isFinite, let previous = lastActivity,
              time >= previous, time - previous < 0.5 else {
            cancel()
            return
        }
        lastActivity = time
        fractionalPixels += smoother.advance(at: time)
        var wholePixels = fractionalPixels.rounded(.towardZero)
        if !smoother.isActive {
            // Correct only floating-point noise at an integer boundary. Genuine
            // subpixel distance carries into the next uninterrupted gesture.
            let nearest = fractionalPixels.rounded()
            if abs(fractionalPixels - nearest) < 1e-9 { wholePixels = nearest }
        }
        if wholePixels != 0 {
            guard abs(wholePixels) <= Double(Int32.max),
                  let event = makeEvent(Int32(wholePixels)) else {
                cancel()
                return
            }
            fractionalPixels -= wholePixels
            event.location = location
            event.flags = flags
            post(event)
        }
        if !smoother.isActive { driver.stop() }
    }

    deinit { driver.stop() }
}
