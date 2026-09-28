import Foundation
@testable import InversoKit
import XCTest

final class SmoothingFrameDriverTests: XCTestCase {
    func testRepeatingFramesUseOwnerRunLoopWhileMainThreadIsBlocked() {
        XCTAssertTrue(Thread.isMainThread)
        let worker = RunLoopWorker()
        let holder = DriverHolder()
        let delivered = DispatchSemaphore(value: 0)
        let count = FrameCount()
        worker.sync {
            let owner = Thread.current
            let driver = RunLoopSmoothingDriver(interval: 0.005)
            holder.driver = driver
            XCTAssertFalse(driver.isRunning)
            XCTAssertTrue(driver.start {
                XCTAssertTrue(Thread.current === owner)
                count.value += 1
                if count.value == 3 { delivered.signal() }
            })
            XCTAssertTrue(driver.isRunning)
        }
        defer { worker.sync { holder.driver = nil } }

        // This deliberately does not pump the main run loop.
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
        worker.sync {
            holder.driver?.stop()
            XCTAssertGreaterThanOrEqual(count.value, 3)
        }
    }

    func testStopPreventsIdleFramesAndRestartDeliversToNewCallback() {
        let worker = RunLoopWorker()
        let holder = DriverHolder()
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        worker.sync {
            let driver = RunLoopSmoothingDriver(interval: 0.005)
            holder.driver = driver
            XCTAssertTrue(driver.start { first.signal() })
        }
        defer { worker.sync { holder.driver = nil } }
        XCTAssertEqual(first.wait(timeout: .now() + 2), .success)
        worker.sync {
            holder.driver?.stop()
            holder.driver?.stop()
            XCTAssertFalse(holder.driver!.isRunning)
        }
        while first.wait(timeout: .now()) == .success {}
        XCTAssertEqual(first.wait(timeout: .now() + 0.05), .timedOut)

        worker.sync { XCTAssertTrue(holder.driver!.start { second.signal() }) }
        XCTAssertEqual(second.wait(timeout: .now() + 2), .success)
        worker.sync { holder.driver?.stop() }
        XCTAssertEqual(first.wait(timeout: .now() + 0.05), .timedOut)
    }

    func testCallbackCanStopItsOwnDriver() {
        let worker = RunLoopWorker()
        let holder = DriverHolder()
        let delivered = DispatchSemaphore(value: 0)
        let count = FrameCount()
        worker.sync {
            let driver = RunLoopSmoothingDriver(interval: 0.005)
            holder.driver = driver
            XCTAssertTrue(driver.start { [weak driver] in
                count.value += 1
                driver?.stop()
                delivered.signal()
            })
        }
        defer { worker.sync { holder.driver = nil } }
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(delivered.wait(timeout: .now() + 0.05), .timedOut)
        worker.sync {
            XCTAssertFalse(holder.driver!.isRunning)
            XCTAssertEqual(count.value, 1)
        }
    }

    func testRepeatedStartKeepsExistingCallback() {
        let worker = RunLoopWorker()
        let holder = DriverHolder()
        let original = DispatchSemaphore(value: 0)
        let replacement = DispatchSemaphore(value: 0)
        worker.sync {
            let driver = RunLoopSmoothingDriver(interval: 0.005)
            holder.driver = driver
            XCTAssertTrue(driver.start { original.signal() })
            XCTAssertTrue(driver.start { replacement.signal() })
        }
        defer { worker.sync { holder.driver = nil } }
        XCTAssertEqual(original.wait(timeout: .now() + 2), .success)
        worker.sync { holder.driver?.stop() }
        XCTAssertEqual(replacement.wait(timeout: .now()), .timedOut)
    }

    func testCallbackCanStopAndRestartWithoutLosingNewTimer() {
        let worker = RunLoopWorker()
        let holder = DriverHolder()
        let restarted = DispatchSemaphore(value: 0)
        worker.sync {
            let driver = RunLoopSmoothingDriver(interval: 0.005)
            holder.driver = driver
            XCTAssertTrue(driver.start { [weak driver] in
                driver?.stop()
                XCTAssertEqual(driver?.start { [weak driver] in
                    driver?.stop()
                    restarted.signal()
                }, true)
            })
        }
        defer { worker.sync { holder.driver = nil } }
        XCTAssertEqual(restarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(restarted.wait(timeout: .now() + 0.05), .timedOut)
        worker.sync { XCTAssertFalse(holder.driver!.isRunning) }
    }

    func testReleasingActiveDriverStopsFramesAndReleasesCallback() {
        let worker = RunLoopWorker()
        let holder = DriverHolder()
        let delivered = DispatchSemaphore(value: 0)
        let callbackReleased = DispatchSemaphore(value: 0)
        weak var released: RunLoopSmoothingDriver?
        worker.sync {
            let driver = RunLoopSmoothingDriver(interval: 0.005)
            holder.driver = driver
            released = driver
            let lifetime = CallbackLifetime(callbackReleased)
            XCTAssertTrue(driver.start {
                _ = withExtendedLifetime(lifetime) { delivered.signal() }
            })
        }
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
        worker.sync { holder.driver = nil }
        XCTAssertNil(released)
        XCTAssertEqual(callbackReleased.wait(timeout: .now() + 2), .success)
        while delivered.wait(timeout: .now()) == .success {}
        XCTAssertEqual(delivered.wait(timeout: .now() + 0.05), .timedOut)
    }

    private final class DriverHolder {
        var driver: RunLoopSmoothingDriver?
    }

    private final class FrameCount {
        var value = 0
    }

    private final class CallbackLifetime {
        let released: DispatchSemaphore
        init(_ released: DispatchSemaphore) { self.released = released }
        deinit { released.signal() }
    }
}
