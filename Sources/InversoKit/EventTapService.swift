import CoreGraphics
import Foundation

/// Input is processed on a dedicated interactive thread. Control calls may wait
/// for that thread, but input callbacks never wait for permission checks or I/O.
public final class EventTapService: EventTapControlling {
    public enum ServiceError: Error, CustomStringConvertible {
        case accessibilityPermissionMissing
        case eventTapCreationFailed
        case runLoopSourceCreationFailed
        case eventTapEnableFailed

        public var description: String {
            switch self {
            case .accessibilityPermissionMissing:
                return "accessibility permission is missing"
            case .eventTapCreationFailed:
                return "could not create the scroll event tap"
            case .runLoopSourceCreationFailed:
                return "could not create the event tap run loop source"
            case .eventTapEnableFailed:
                return "could not enable the scroll event tap"
            }
        }
    }

    private let worker: RunLoopWorker
    private let state: EventTapState
    private let permissionGranted: () -> Bool

    public convenience init() {
        self.init(permissionGranted: { Accessibility.isTrusted },
                  makeConnection: { try SystemEventTapConnection(handler: $0) })
    }

    init(permissionGranted: @escaping () -> Bool, makeConnection: @escaping EventTapFactory) {
        self.permissionGranted = permissionGranted
        state = EventTapState(makeConnection: makeConnection)
        worker = RunLoopWorker()
    }

    public var isRunning: Bool {
        worker.sync { [state] in state.isRunning }
    }

    var disableStats: TapDisableStats {
        worker.sync { [state] in state.disableStats }
    }

    public func start() throws {
        // AXIsProcessTrusted may perform IPC. Never run it on the input thread.
        guard permissionGranted() else { throw ServiceError.accessibilityPermissionMissing }
        try worker.sync { [state] in Result { try state.start() } }.get()
    }

    public func stop() {
        worker.sync { [state] in state.stop() }
    }

    deinit { stop() }

    /// A read-only snapshot, not a guarantee that an application consumes the event.
    /// nil means the system could not supply a complete tap list.
    public static func hasEnabledScrollTap(processID: Int32) -> Bool? {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        var capacity = count + 8
        // With a non-nil buffer the API reports entries filled, not total taps.
        // A full buffer might omit a newly created tap: grow it before saying no.
        for _ in 0..<3 {
            var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(capacity))
            var actualCount: UInt32 = 0
            guard CGGetEventTapList(capacity, &taps, &actualCount) == .success else { return nil }
            if taps.prefix(Int(min(actualCount, capacity))).contains(where: {
                $0.tappingProcess == processID && $0.enabled
                    && $0.options == .defaultTap && ($0.eventsOfInterest & mask) != 0
            }) { return true }
            if actualCount < capacity { return false }
            capacity = max(capacity * 2, actualCount + 8)
        }
        return nil
    }
}

/// How often macOS disabled the scroll tap; each was re-enabled immediately.
struct TapDisableStats: Equatable {
    var timeouts = 0
    var userInput = 0
    var last: Date?
}

/// All state, including recovery from callbacks, belongs to one run loop. It
/// never calls back into the control thread or acquires a control-side lock.
private final class EventTapState {
    private let makeConnection: EventTapFactory
    private var connection: EventTapConnection?
    private(set) var disableStats = TapDisableStats()

    init(makeConnection: @escaping EventTapFactory) {
        self.makeConnection = makeConnection
    }

    var isRunning: Bool {
        guard let connection else { return false }
        return connection.isValid && connection.isEnabled
    }

    func start() throws {
        if isRunning { return }
        if let connection, connection.isValid {
            connection.setEnabled(true)
            if isRunning { return }
        }
        stop()
        do {
            connection = try makeConnection { [weak self] type, event in
                guard let self else { return Unmanaged.passUnretained(event) }
                return self.handle(type: type, event: event)
            }
        } catch {
            stop()
            throw error
        }
        connection?.setEnabled(true)
        guard isRunning else {
            stop()
            throw EventTapService.ServiceError.eventTapEnableFailed
        }
    }

    func stop() {
        connection?.invalidate()
        connection = nil
    }

    /// Reverses in place and returns immediately: no allocation, I/O or WindowServer call.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Counted here, reported by the control thread: no logging on input.
            if type == .tapDisabledByTimeout { disableStats.timeouts += 1 } else { disableStats.userInput += 1 }
            disableStats.last = Date()
            if let connection, connection.isValid { connection.setEnabled(true) }
        } else if type == .scrollWheel {
            ScrollTransform.reverseMouseWheelEvent(event)
        }
        return Unmanaged.passUnretained(event)
    }
}
