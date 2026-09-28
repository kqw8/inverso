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
    /// Only wheel events: pointer, button and key events never wait for this daemon.
    static let eventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

    private let handler: ScrollEventHandler
    private let runLoop = CFRunLoopGetCurrent()!
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    init(handler: @escaping ScrollEventHandler) throws {
        self.handler = handler
        guard let port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw EventTapService.ServiceError.eventTapCreationFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw EventTapService.ServiceError.runLoopSourceCreationFailed
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(runLoop, source, .commonModes)
    }

    var isValid: Bool {
        guard let port, let source else { return false }
        return CFMachPortIsValid(port) && CFRunLoopSourceIsValid(source)
    }

    var isEnabled: Bool {
        guard isValid, let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func setEnabled(_ enabled: Bool) {
        guard let port, CFMachPortIsValid(port) else { return }
        CGEvent.tapEnable(tap: port, enable: enabled)
    }

    func invalidate() {
        setEnabled(false)
        if let source {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let port { CFMachPortInvalidate(port) }
        source = nil
        port = nil
    }

    deinit { invalidate() }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let connection = Unmanaged<SystemEventTapConnection>.fromOpaque(context).takeUnretainedValue()
        return autoreleasepool { connection.handler(type, event) }
    }
}
