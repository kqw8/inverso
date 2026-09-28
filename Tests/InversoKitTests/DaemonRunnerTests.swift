@testable import InversoKit
import XCTest

final class DaemonRunnerTests: XCTestCase {
    func testPermissionLossStopsTapAndRegrantRestartsIt() {
        let service = StubTap()
        var trusted = false
        var prompts = 0
        var messages: [String] = []
        let runner = DaemonRunner(service: service, permissionGranted: { trusted },
                                  requestPermission: { prompts += 1 }, report: { messages.append($0) })
        runner.refresh()
        runner.refresh()
        XCTAssertEqual(service.starts, 0)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(messages.count, 1)

        trusted = true
        runner.refresh()
        runner.refresh()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(service.starts, 1)

        trusted = false
        runner.refresh()
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(prompts, 1)

        trusted = true
        runner.refresh()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(service.starts, 2)
    }

    func testSuccessfulStartDoesNotPreventLaterRecovery() {
        let service = StubTap()
        let runner = DaemonRunner(service: service, permissionGranted: { true },
                                  requestPermission: {}, report: { _ in })
        runner.refresh()
        service.isRunning = false // Simulate an invalidated or silently disabled tap.
        runner.refresh()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(service.starts, 2)
    }

    func testCreationFailuresAreRetriedWithoutRepeatedLogMessages() {
        let service = StubTap()
        service.failStart = true
        var messages: [String] = []
        let runner = DaemonRunner(service: service, permissionGranted: { true },
                                  requestPermission: {}, report: { messages.append($0) })
        runner.refresh()
        runner.refresh()
        XCTAssertEqual(service.starts, 2)
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(service.isRunning)
        service.failStart = false
        runner.refresh()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(messages.count, 2)
    }

    func testTapDisablesAreReportedOncePerIncreaseWithoutRepeatingReady() throws {
        let service = StubTap()
        var messages: [String] = []
        let runner = DaemonRunner(service: service, permissionGranted: { true },
                                  requestPermission: {}, report: { messages.append($0) })
        runner.refresh()
        XCTAssertEqual(messages, ["scroll event tap is ready."])
        service.disableStats = TapDisableStats(timeouts: 2, userInput: 0, last: Date())
        runner.refresh()
        runner.refresh()
        XCTAssertEqual(messages.count, 2)
        let first = try XCTUnwrap(messages.dropFirst().first)
        XCTAssertTrue(first.contains("2 time"), first)
        XCTAssertTrue(first.contains("2 timeout"), first)
        // An invalid tap cannot be re-enabled; the health check rebuilds it.
        XCTAssertTrue(first.contains("rebuilds"), first)
        service.disableStats.userInput = 1
        runner.refresh()
        XCTAssertEqual(messages.count, 3)
        let second = try XCTUnwrap(messages.dropFirst(2).first)
        XCTAssertTrue(second.contains("1 time"), second)
        XCTAssertTrue(second.contains("1 user-input"), second)
        XCTAssertFalse(messages.dropFirst().contains("scroll event tap is ready."))
    }

    func testLogLinesStartWithALocalISO8601Timestamp() throws {
        let line = DaemonRunner.logLine("scroll event tap is ready.", date: Date(timeIntervalSince1970: 0))
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2}) inverso: scroll event tap is ready\.\n$"#
        XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), line)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = try XCTUnwrap(line.split(separator: " ").first)
        XCTAssertEqual(formatter.date(from: String(stamp)), Date(timeIntervalSince1970: 0))
        let offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(stamp.hasSuffix("Z"), offset == 0, "timestamps use the local time zone")
    }

    private final class StubTap: EventTapControlling {
        var isRunning = false
        var disableStats = TapDisableStats()
        var failStart = false
        var starts = 0

        func start() throws {
            starts += 1
            if failStart { throw EventTapService.ServiceError.eventTapCreationFailed }
            isRunning = true
        }

        func stop() { isRunning = false }
    }
}
