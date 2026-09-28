import Foundation
@testable import InversoKit
import XCTest

final class SingleInstanceLockTests: XCTestCase {
    func testSecondOwnerIsRejectedAndReleaseAllowsNewOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("daemon.lock")
        var first: SingleInstanceLock? = try SingleInstanceLock(url: url)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try SingleInstanceLock(url: url)) { error in
                guard case SingleInstanceLock.LockError.alreadyRunning = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        first = nil
        // The persistent file itself must not be mistaken for an active lock.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let next = try SingleInstanceLock(url: url)
        withExtendedLifetime(next) {}
    }

    func testWaitingOwnerReportsOnceAndAcquiresAfterRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("daemon.lock")
        var first: SingleInstanceLock? = try SingleInstanceLock(url: url)
        let waiting = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var waits = 0
        var second: SingleInstanceLock?
        var failure: Error?
        Thread.detachNewThread {
            do {
                second = try SingleInstanceLock(url: url, waitIfHeld: true, onWait: {
                    waits += 1
                    waiting.signal()
                })
            } catch {
                failure = error
            }
            finished.signal()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 2), .success, "a held lock must be reported")
        XCTAssertEqual(finished.wait(timeout: .now() + 0.2), .timedOut, "must wait while the lock is held")
        withExtendedLifetime(first) {}
        first = nil
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success, "must acquire after release")
        XCTAssertNil(failure)
        XCTAssertNotNil(second)
        XCTAssertEqual(waits, 1)
    }

    func testDoesNotFollowSymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("existing.txt")
        let url = directory.appendingPathComponent("daemon.lock")
        try "unchanged".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try SingleInstanceLock(url: url))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }
}
