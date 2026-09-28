import CoreGraphics

/// Builds this daemon's marked synthetic pixel scroll events from one source.
/// Creating a source is a synchronous WindowServer call, and every private
/// source pins a shared WindowServer page until the process exits.
final class PixelEventFactory {
    private let source: CGEventSource

    init?(makeSource: () -> CGEventSource? = { CGEventSource(stateID: .privateState) }) {
        guard let source = makeSource() else { return nil }
        // Mark the source once. Re-marking copied vendor events is unreliable.
        source.userData = ScrollTransform.syntheticMarker
        self.source = source
    }

    func make(pixels: Int32) -> CGEvent? {
        CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)
    }
}
