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
