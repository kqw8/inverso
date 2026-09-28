@testable import InversoKit
import CoreGraphics
import XCTest

final class EventTapServiceTests: XCTestCase {
    func testSpeedAppliesLiveAndSurvivesTapRecreation() throws {
        var connections: [TestConnection] = []
        let driver = TestFrameDriver()
        var time = 0.0
        var pixels: [Int64] = []
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connections.append(tap)
            return tap
        }, makeProcessor: {
            ScrollEventProcessor(driver: driver, now: { time }, makeEvent: { pixels in
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: pixels, wheel2: 0, wheel3: 0)
            }, post: { pixels.append($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) })
        })
        defer { service.stop() }

        func scrollOneNotch() throws {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                             wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
            event.flags = []
            let completed = DispatchSemaphore(value: 0)
            connections.last!.enqueue(.scrollWheel, event: event) {
                time += 0.1
                driver.frame?()
                completed.signal()
            }
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        }

        service.setScrollSpeed(1.5)
        try service.start()
        try scrollOneNotch()
        service.setScrollSpeed(2)
        try scrollOneNotch()
        XCTAssertEqual(connections.count, 1)
        service.stop()
        try service.start()
        try scrollOneNotch()
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(pixels, [-60, -80, -80])
    }

    func testOnlyScrollWheelEventsReachTheDaemon() {
        // Pointer, button and key events must never wait for or wake this daemon.
        XCTAssertEqual(SystemEventTapConnection.eventMask, CGEventMask(1 << CGEventType.scrollWheel.rawValue))
    }

    func testServicePreservesSmoothingSuppressionAndCancelsOnDisable() throws {
        var connection: TestConnection?
        let driver = TestFrameDriver()
        var posted = 0
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connection = tap
            return tap
        }, makeProcessor: {
            ScrollEventProcessor(driver: driver, now: { 0 }, makeEvent: { pixels in
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: pixels, wheel2: 0, wheel3: 0)
            }, post: { _ in posted += 1 })
        })
        defer { service.stop() }
        try service.start()
        let tap = try XCTUnwrap(connection)
        let wheelDelivered = DispatchSemaphore(value: 0)
        var suppressed = false
        let event = try wheel()
        event.flags = []
        tap.enqueue(.scrollWheel, event: event, inspect: { suppressed = $0 == nil }) {
            wheelDelivered.signal()
        }
        XCTAssertEqual(wheelDelivered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(suppressed, "The tap must preserve nil from the smoothing callback")
        XCTAssertTrue(driver.isRunning)

        let disabled = DispatchSemaphore(value: 0)
        tap.enqueue(.tapDisabledByTimeout, event: event) { disabled.signal() }
        XCTAssertEqual(disabled.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(driver.isRunning)
        XCTAssertEqual(posted, 0)
        XCTAssertTrue(service.isRunning)
    }

    func testPermissionCheckStaysOnCallerAndTapLivesOnWorker() throws {
        let caller = Thread.current
        var permissionThread: Thread?
        var connection: TestConnection?
        let service = EventTapService(permissionGranted: {
            permissionThread = Thread.current
            return true
        }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connection = tap
            return tap
        })
        try service.start()
        XCTAssertTrue(permissionThread === caller)
        XCTAssertFalse(try XCTUnwrap(connection).owner === caller)
        XCTAssertEqual(connection?.owner.qualityOfService, .userInteractive)
        XCTAssertTrue(service.isRunning)
        service.stop()
        XCTAssertFalse(service.isRunning)
        XCTAssertTrue(connection?.invalidationThread === connection?.owner)
    }

    func testInputContinuesWhilePermissionCheckBlocksCaller() throws {
        let event = try wheel()
        let delivered = DispatchSemaphore(value: 0)
        var connection: TestConnection?
        var blockPermission = false
        var received = false
        let service = EventTapService(permissionGranted: {
            if blockPermission {
                connection?.enqueue(.scrollWheel, event: event) { delivered.signal() }
                // This does not pump the main run loop. An event source on main
                // would be stuck behind this permission query.
                received = delivered.wait(timeout: .now() + 2) == .success
            }
            return true
        }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connection = tap
            return tap
        })
        defer { service.stop() }
        try service.start()
        blockPermission = true
        try service.start()
        XCTAssertTrue(received, "input must not depend on permission IPC returning")
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -21)
    }

    func testHealthyStartDoesNotReplaceOrReenableTap() throws {
        var creations = 0
        var connection: TestConnection?
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            creations += 1
            let tap = TestConnection(handler: handler)
            connection = tap
            return tap
        })
        defer { service.stop() }
        try service.start()
        try service.start()
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(connection?.enables, 1)
    }

    func testMissingPermissionDoesNotCreateTap() {
        var creations = 0
        let service = EventTapService(permissionGranted: { false }, makeConnection: { handler in
            creations += 1
            return TestConnection(handler: handler)
        })
        XCTAssertThrowsError(try service.start())
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(creations, 0)
    }

    func testCreateFailureCanBeRetried() throws {
        var creations = 0
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            creations += 1
            if creations == 1 { throw EventTapService.ServiceError.eventTapCreationFailed }
            return TestConnection(handler: handler)
        })
        defer { service.stop() }
        XCTAssertThrowsError(try service.start())
        XCTAssertFalse(service.isRunning)
        try service.start()
        XCTAssertTrue(service.isRunning)
    }

    func testEnableFailureInvalidatesConnectionBeforeRetry() throws {
        var connections: [TestConnection] = []
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            tap.canEnable = !connections.isEmpty
            connections.append(tap)
            return tap
        })
        defer { service.stop() }
        XCTAssertThrowsError(try service.start())
        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(connections[0].isValid)
        try service.start()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(connections.count, 2)
    }

    func testDisabledTapRecoversWithoutReplacement() throws {
        var connections: [TestConnection] = []
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connections.append(tap)
            return tap
        })
        defer { service.stop() }
        try service.start()
        connections[0].isEnabled = false
        XCTAssertFalse(service.isRunning)
        try service.start()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(connections.count, 1)
    }

    func testInvalidTapIsInvalidatedAndReplaced() throws {
        var connections: [TestConnection] = []
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connections.append(tap)
            return tap
        })
        defer { service.stop() }
        try service.start()
        connections[0].isValid = false
        XCTAssertFalse(service.isRunning)
        try service.start()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(connections[0].invalidations, 1)
    }

    func testDisableNotificationsReenableBeforeCallbackReturns() throws {
        var connection: TestConnection?
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connection = tap
            return tap
        })
        defer { service.stop() }
        try service.start()
        let tap = try XCTUnwrap(connection)
        for type: CGEventType in [.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let event = try wheel()
            tap.isEnabled = false
            let done = DispatchSemaphore(value: 0)
            var enabledOnReturn = false
            tap.enqueue(type, event: event) {
                enabledOnReturn = tap.isEnabled
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
            XCTAssertTrue(enabledOnReturn)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 3)
        }
    }

    func testCallbackReturnsOriginalEventAndPreservesTrackpad() throws {
        var connection: TestConnection?
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connection = tap
            return tap
        })
        defer { service.stop() }
        try service.start()
        let tap = try XCTUnwrap(connection)
        let event = try wheel()
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        let before = ScrollTransform.verticalSample(from: event)
        let done = DispatchSemaphore(value: 0)
        var returnedSame = false
        tap.enqueue(.scrollWheel, event: event, inspect: { returned in
            returnedSame = returned === event
        }) { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(returnedSame)
        XCTAssertEqual(ScrollTransform.verticalSample(from: event), before)
    }

    func testStopIsIdempotentAndCanRestart() throws {
        var connections: [TestConnection] = []
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connections.append(tap)
            return tap
        })
        try service.start()
        service.stop()
        service.stop()
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(connections[0].invalidations, 1)
        try service.start()
        XCTAssertTrue(service.isRunning)
        service.stop()
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(connections[1].invalidations, 1)
    }

    func testDeinitInvalidatesConnectionOnItsOwnerThread() throws {
        var connection: TestConnection?
        var service: EventTapService? = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connection = tap
            return tap
        })
        try service?.start()
        weak let released = service
        service = nil
        XCTAssertNil(released)
        XCTAssertEqual(connection?.invalidations, 1)
        XCTAssertTrue(connection?.invalidationThread === connection?.owner)
    }

    func testConcurrentStartStopLeavesNoLiveConnections() throws {
        var connections: [TestConnection] = [] // Accessed by factory on worker only.
        let service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connections.append(tap)
            return tap
        })
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                for _ in 0..<25 {
                    do { try service.start() }
                    catch { XCTFail("Concurrent start failed: \(error)") }
                    service.stop()
                }
            }
            completed.signal()
        }
        guard completed.wait(timeout: .now() + 5) == .success else {
            return XCTFail("Concurrent lifecycle operations deadlocked")
        }
        try service.start()
        XCTAssertTrue(service.isRunning)
        service.stop()
        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(connections.isEmpty)
        XCTAssertTrue(connections.allSatisfy { !$0.isValid && $0.invalidations == 1 })
    }

    func testLastServiceOwnerCanBeReleasedOnEventThread() throws {
        final class Holder { var service: EventTapService? }
        let holder = Holder()
        var connection: TestConnection?
        holder.service = EventTapService(permissionGranted: { true }, makeConnection: { handler in
            let tap = TestConnection(handler: handler)
            connection = tap
            return tap
        })
        try holder.service?.start()
        weak let released = holder.service
        let tap = try XCTUnwrap(connection)
        let completed = DispatchSemaphore(value: 0)
        tap.enqueue(.scrollWheel, event: try wheel()) {
            holder.service = nil
            completed.signal()
        }
        guard completed.wait(timeout: .now() + 2) == .success else {
            return XCTFail("Service teardown on its event thread deadlocked")
        }
        XCTAssertNil(released)
        XCTAssertEqual(tap.invalidations, 1)
        XCTAssertTrue(tap.invalidationThread === tap.owner)
        let deadline = Date().addingTimeInterval(2)
        while !tap.owner.isFinished && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(tap.owner.isFinished)
    }

    private func wheel() throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                         wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 21)
        return event
    }
}

private final class TestFrameDriver: SmoothingFrameDriving {
    var frame: (() -> Void)?
    var isRunning: Bool { frame != nil }
    func start(_ onFrame: @escaping () -> Void) -> Bool { frame = onFrame; return true }
    func stop() { frame = nil }
}

/// Only the system/TCC connection is replaced. The production worker, callback,
/// transformation and lifecycle state machine all execute normally.
private final class TestConnection: EventTapConnection {
    let owner = Thread.current
    let loop = CFRunLoopGetCurrent()!
    let handler: ScrollEventHandler
    var isValid = true
    var isEnabled = false
    var canEnable = true
    var enables = 0
    var invalidations = 0
    var invalidationThread: Thread?

    init(handler: @escaping ScrollEventHandler) { self.handler = handler }

    func setEnabled(_ enabled: Bool) {
        precondition(Thread.current === owner)
        if enabled { enables += 1 }
        isEnabled = enabled && canEnable
    }

    func invalidate() {
        precondition(Thread.current === owner)
        invalidationThread = Thread.current
        invalidations += 1
        isEnabled = false
        isValid = false
    }

    func enqueue(_ type: CGEventType, event: CGEvent,
                 inspect: @escaping (CGEvent?) -> Void = { _ in },
                 completion: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            inspect(self.handler(type, event)?.takeUnretainedValue())
            completion()
        }
        CFRunLoopWakeUp(loop)
    }
}
