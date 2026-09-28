import CoreGraphics
import Foundation

typealias ScrollEventHandler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?
typealias EventTapFactory = (@escaping ScrollEventHandler) throws -> EventTapConnection

/// Confined to the event thread, including construction and invalidation.
protocol EventTapConnection: AnyObject {
    var isValid: Bool { get }
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
    func invalidate()
}

/// Owns the system resources; no permission checks or logging belong here.
final class SystemEventTapConnection: EventTapConnection {
    struct TapSpecification {
        let mask: CGEventMask
        let options: CGEventTapOptions
    }

    private struct Tap {
        let port: CFMachPort
        let source: CFRunLoopSource
    }

    private let handler: ScrollEventHandler
    private let runLoop = CFRunLoopGetCurrent()!
    private var taps: [Tap] = []

    init(smoothingEnabled: Bool = false, handler: @escaping ScrollEventHandler) throws {
        self.handler = handler
        do {
            for specification in Self.tapSpecifications(smoothingEnabled: smoothingEnabled) {
                guard let port = CGEvent.tapCreate(
                    tap: .cgAnnotatedSessionEventTap,
                    place: .tailAppendEventTap,
                    options: specification.options,
                    eventsOfInterest: specification.mask,
                    callback: Self.callback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque()
                ) else {
                    throw EventTapService.ServiceError.eventTapCreationFailed
                }
                guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                    CFMachPortInvalidate(port)
                    throw EventTapService.ServiceError.runLoopSourceCreationFailed
                }
                taps.append(Tap(port: port, source: source))
                CFRunLoopAddSource(runLoop, source, .commonModes)
            }
        } catch {
            // A failure in either tap must release the already-created half.
            invalidate()
            throw error
        }
    }

    var isValid: Bool {
        !taps.isEmpty && taps.allSatisfy { CFMachPortIsValid($0.port) && CFRunLoopSourceIsValid($0.source) }
    }

    var isEnabled: Bool {
        isValid && taps.allSatisfy { CGEvent.tapIsEnabled(tap: $0.port) }
    }

    func setEnabled(_ enabled: Bool) {
        for tap in taps where CFMachPortIsValid(tap.port) {
            CGEvent.tapEnable(tap: tap.port, enable: enabled)
        }
    }

    func invalidate() {
        setEnabled(false)
        for tap in taps {
            CFRunLoopRemoveSource(runLoop, tap.source, .commonModes)
            CFRunLoopSourceInvalidate(tap.source)
            CFMachPortInvalidate(tap.port)
        }
        taps.removeAll()
    }

    deinit { invalidate() }

    static func tapSpecifications(smoothingEnabled: Bool) -> [TapSpecification] {
        var specifications = [TapSpecification(mask: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                               options: .defaultTap)]
        if smoothingEnabled {
            let contextTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .flagsChanged]
            let mask = contextTypes.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
            // High-rate pointer movement must never wait for this daemon. This
            // observer only cancels old smooth output; it cannot block or edit input.
            specifications.append(TapSpecification(mask: mask, options: .listenOnly))
        }
        return specifications
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let connection = Unmanaged<SystemEventTapConnection>.fromOpaque(context).takeUnretainedValue()
        return autoreleasepool { connection.handler(type, event) }
    }
}
