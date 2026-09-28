@testable import InversoKit
import XCTest

final class DaemonRunnerTests: XCTestCase {
    func testLoadsSpeedOnControlThreadBeforeStarting() throws {
        let service = StubTap()
        let caller = Thread.current
        var loaderThread: Thread?
        let runner = DaemonRunner(service: service, permissionGranted: { true },
            requestPermission: {}, report: { _ in }, loadSettings: {
                loaderThread = Thread.current
                return try ScrollSettings(speedMultiplier: 1.5)
            })
        runner.refresh()
        XCTAssertTrue(loaderThread === caller)
        XCTAssertEqual(service.speedAtStart, 1.5)
    }

    func testReloadChangesSpeedWithoutRestartingTheTap() throws {
        let service = StubTap()
        var settings = try ScrollSettings(speedMultiplier: 1)
        let runner = DaemonRunner(service: service, permissionGranted: { true },
            requestPermission: {}, report: { _ in }, loadSettings: { settings })
        runner.refresh()
        settings = try ScrollSettings(speedMultiplier: 1.5)
        runner.refresh()
        runner.refresh()
        XCTAssertEqual(service.speedMultiplier, 1.5)
        XCTAssertEqual(service.starts, 1)
        XCTAssertEqual(service.speedUpdates, [1, 1.5])
    }

    func testInvalidSettingsRetainLastGoodSpeedAndReportOnce() throws {
        let service = StubTap()
        var unreadable = false
        var settings = try ScrollSettings(speedMultiplier: 1.75)
        var messages: [String] = []
        let runner = DaemonRunner(service: service, permissionGranted: { true },
            requestPermission: {}, report: { messages.append($0) }, loadSettings: {
                if unreadable { throw NSError(domain: "settings-test", code: 1) }
                return settings
            })
        runner.refresh()
        unreadable = true
        runner.refresh()
        runner.refresh()
        XCTAssertEqual(service.speedMultiplier, 1.75)
        XCTAssertEqual(messages.filter { $0.contains("settings-test") }.count, 1)
        XCTAssertTrue(service.isRunning)

        unreadable = false
        settings = try ScrollSettings(speedMultiplier: 0.5)
        runner.refresh()
        XCTAssertEqual(service.speedMultiplier, 0.5)
        unreadable = true
        runner.refresh()
        XCTAssertEqual(messages.filter { $0.contains("settings-test") }.count, 2)
        XCTAssertEqual(service.starts, 1)
    }

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
        var speedMultiplier = 1.0
        var speedAtStart = 1.0
        var speedUpdates: [Double] = []

        func setScrollSpeed(_ multiplier: Double) {
            speedMultiplier = multiplier
            speedUpdates.append(multiplier)
        }

        func start() throws {
            starts += 1
            speedAtStart = speedMultiplier
            if failStart { throw EventTapService.ServiceError.eventTapCreationFailed }
            isRunning = true
        }

        func stop() { isRunning = false }
    }
}
