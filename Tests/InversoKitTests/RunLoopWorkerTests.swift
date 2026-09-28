import CoreFoundation
import Foundation
@testable import InversoKit
import XCTest

final class RunLoopWorkerTests: XCTestCase {
    func testOperationsUseOneInteractiveThreadAndReturnValues() {
        let worker = RunLoopWorker(name: "inverso.tests.events")
        let thread = worker.sync { Thread.current }
        XCTAssertFalse(thread.isMainThread)
        XCTAssertEqual(thread.name, "inverso.tests.events")
        XCTAssertEqual(thread.qualityOfService, .userInteractive)
        for value in 0..<20 {
            XCTAssertEqual(worker.sync {
                XCTAssertTrue(Thread.current === thread)
                return value * 2
            }, value * 2)
        }
    }

    func testNestedOperationRunsInlineWithoutDeadlock() {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let worker = RunLoopWorker()
            let result = worker.sync {
                let outerThread = Thread.current
                return worker.sync {
                    XCTAssertTrue(Thread.current === outerThread)
                    return 42
                }
            }
            XCTAssertEqual(result, 42)
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }

    func testConcurrentCallersSerializeOperationsWithoutLosingUpdates() {
        let worker = RunLoopWorker()
        let finished = DispatchSemaphore(value: 0)
        // Only the worker accesses this value, even with many submitting callers.
        let counter = WorkerCounter()
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                var previous = 0
                for _ in 0..<50 {
                    let value = worker.sync {
                        counter.value += 1
                        return counter.value
                    }
                    XCTAssertGreaterThan(value, previous)
                    previous = value
                }
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success else {
            return XCTFail("Concurrent worker operations did not complete")
        }
        XCTAssertEqual(worker.sync { counter.value }, 400)
    }

    func testRunLoopSourceIsDeliveredWhileMainThreadIsBlocked() throws {
        XCTAssertTrue(Thread.isMainThread)
        let worker = RunLoopWorker()
        let delivery = SourceDelivery()
        let (loop, source): (CFRunLoop, CFRunLoopSource) = try worker.sync {
            Result {
                var context = CFRunLoopSourceContext()
                context.info = Unmanaged.passUnretained(delivery).toOpaque()
                context.perform = { info in
                    let delivery = Unmanaged<SourceDelivery>.fromOpaque(info!).takeUnretainedValue()
                    delivery.deliveredOnMain = Thread.isMainThread
                    delivery.finished.signal()
                }
                let source = try XCTUnwrap(CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context))
                let loop = CFRunLoopGetCurrent()!
                CFRunLoopAddSource(loop, source, .defaultMode)
                return (loop, source)
            }
        }.get()
        defer {
            worker.sync {
                CFRunLoopRemoveSource(loop, source, .defaultMode)
                CFRunLoopSourceInvalidate(source)
            }
            withExtendedLifetime(delivery) {}
        }
        CFRunLoopSourceSignal(source)
        CFRunLoopWakeUp(loop)
        // A semaphore deliberately prevents XCTest from pumping the main run loop.
        XCTAssertEqual(delivery.finished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(delivery.deliveredOnMain)
    }

    func testReleaseStopsTheThreadAndDoesNotRetainWorker() {
        for _ in 0..<20 {
            var worker: RunLoopWorker? = RunLoopWorker()
            weak let weakWorker = worker
            let thread = worker!.sync { Thread.current }
            worker = nil
            XCTAssertNil(weakWorker)
            assertFinished(thread)
        }
    }

    func testLastOwnerCanBeReleasedOnWorkerThread() {
        let holder = WorkerHolder()
        holder.worker = RunLoopWorker()
        weak let weakWorker = holder.worker
        let (loop, thread) = holder.worker!.sync { (CFRunLoopGetCurrent()!, Thread.current) }
        let released = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            holder.worker = nil
            released.signal()
        }
        CFRunLoopWakeUp(loop)
        guard released.wait(timeout: .now() + 2) == .success else {
            return XCTFail("Releasing the worker on its thread deadlocked")
        }
        XCTAssertNil(weakWorker)
        assertFinished(thread)
    }

    func testEachOperationDrainsItsAutoreleasePoolBeforeReturning() {
        let worker = RunLoopWorker()
        let released = DispatchSemaphore(value: 0)
        worker.sync {
            _ = Unmanaged.passRetained(ReleaseSignal(released)).autorelease()
        }
        XCTAssertEqual(released.wait(timeout: .now()), .success)
    }

    private func assertFinished(_ thread: Thread, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !thread.isFinished && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(thread.isFinished, "Worker thread did not exit", file: file, line: line)
    }

    private final class WorkerCounter {
        var value = 0
    }

    private final class WorkerHolder {
        var worker: RunLoopWorker?
    }

    private final class SourceDelivery {
        let finished = DispatchSemaphore(value: 0)
        var deliveredOnMain = true
    }

    private final class ReleaseSignal: NSObject {
        let released: DispatchSemaphore
        init(_ released: DispatchSemaphore) { self.released = released }
        deinit { released.signal() }
    }
}
