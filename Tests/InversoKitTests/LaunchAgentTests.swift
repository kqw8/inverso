@testable import InversoKit
import XCTest

final class LaunchAgentTests: XCTestCase {
    // Representative launchctl print output, including nested state fields that
    // must not overwrite the service's own process state.
    private let runningOutput = """
    gui/501/com.kqw8.inverso = {
    \tpath = /Users/test/Library/LaunchAgents/com.kqw8.inverso.plist
    \tstate = running
    \targuments = {
    \t\t/usr/local/bin/inverso
    \t\t--daemon
    \t}
    \tpid = 856
    \tresource coalition = {
    \t\tstate = active
    \t\tpid = 999
    \t}
    }
    """

    private let missingOutput = """
    Bad request.
    Could not find service "com.kqw8.inverso" in domain for user gui: 501
    """

    func testPlistRoundTripsSpecialCharactersInExecutableAndLogPaths() throws {
        let executable = "/tmp/R&D/<工具> \"test\"/inverso"
        let home = URL(fileURLWithPath: "/tmp/用户 & <home>")
        let contents = LaunchAgent.plistContents(executablePath: executable, homeDirectory: home)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contents.utf8), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.kqw8.inverso")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [executable, "--daemon"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        // The installed input filter must not be subject to background throttling.
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["StandardOutPath"] as? String, home.appendingPathComponent("Library/Logs/inverso.out.log").path)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, home.appendingPathComponent("Library/Logs/inverso.err.log").path)
    }

    func testWritePlistCreatesLaunchAgentAndLogsDirectories() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("inverso-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try LaunchAgent.writePlist(executablePath: "/tmp/R&D/inverso", homeDirectory: home)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/tmp/R&D/inverso", "--daemon"])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Logs").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRunningStatusUsesOnlyTopLevelFields() throws {
        let status = try LaunchAgent.serviceStatus { _ in (0, runningOutput) }
        XCTAssertTrue(status.isLoaded)
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.pid, 856)
        XCTAssertEqual(status.state, "running")
    }

    func testLoadedServiceWithoutProcessIsNotRunning() throws {
        let output = "gui/501/com.kqw8.inverso = {\n\tstate = spawn scheduled\n\tlast exit code = 1\n}"
        let status = try LaunchAgent.serviceStatus { _ in (0, output) }
        XCTAssertTrue(status.isLoaded)
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.pid)
    }

    func testUnrecognizedProcessOutputDoesNotClaimRunning() throws {
        let status = try LaunchAgent.serviceStatus { _ in (0, "new output format") }
        XCTAssertTrue(status.isLoaded)
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.state)
        XCTAssertNil(status.pid)
    }

    func testKnownMissingServiceIsNotLoaded() throws {
        let status = try LaunchAgent.serviceStatus { _ in (113, missingOutput) }
        XCTAssertFalse(status.isLoaded)
        XCTAssertFalse(status.isRunning)
    }

    func testFailedQueryRetainsDiagnosticAndDoesNotMeanUnloaded() {
        XCTAssertThrowsError(try LaunchAgent.serviceStatus { _ in (1, "Operation not permitted") }) { error in
            XCTAssertTrue(String(describing: error).contains("Operation not permitted"))
            XCTAssertTrue(String(describing: error).contains("exit 1"))
        }
        XCTAssertThrowsError(try LaunchAgent.serviceStatus { _ in (113, "Could not find domain for user gui: 501") })
    }

    func testUnloadDoesNotActWhenInitialQueryFails() {
        var commands: [String] = []
        XCTAssertThrowsError(try LaunchAgent.unloadService { arguments in
            commands.append(arguments[0])
            return (1, "Operation not permitted")
        })
        XCTAssertEqual(commands, ["print"])
    }

    func testUnloadRequiresSuccessfulVerification() {
        var commands: [String] = []
        XCTAssertThrowsError(try LaunchAgent.unloadService { arguments in
            commands.append(arguments[0])
            if commands.count == 1 { return (0, runningOutput) }
            if arguments[0] == "bootout" { return (0, "") }
            return (1, "Operation not permitted")
        })
        XCTAssertEqual(commands, ["print", "bootout", "print"])
    }

    func testUnloadVerifiesServiceAbsence() throws {
        var commands: [String] = []
        try LaunchAgent.unloadService { arguments in
            commands.append(arguments[0])
            if commands.count == 1 { return (0, runningOutput) }
            if arguments[0] == "bootout" { return (0, "") }
            return (113, missingOutput)
        }
        XCTAssertEqual(commands, ["print", "bootout", "print"])
    }

    func testBootstrapFailureDoesNotBecomeSuccessfulLoad() {
        var commands: [String] = []
        XCTAssertThrowsError(try LaunchAgent.loadService { arguments in
            commands.append(arguments[0])
            if arguments[0] == "print" { return (113, missingOutput) }
            return (5, "Bootstrap failed: 5: Input/output error")
        }) { error in
            XCTAssertTrue(String(describing: error).contains("Bootstrap failed: 5"))
        }
        XCTAssertEqual(commands, ["print", "bootstrap"])
    }

    func testParsesDisabledStateVariantsAndExactLabel() {
        XCTAssertEqual(LaunchAgent.disabledState(for: LaunchAgent.label, in: "\"com.kqw8.inverso\" => true"), true)
        XCTAssertEqual(LaunchAgent.disabledState(for: LaunchAgent.label, in: "\"com.kqw8.inverso\" => enabled"), false)
        XCTAssertNil(LaunchAgent.disabledState(for: LaunchAgent.label, in: "\"com.kqw8.inverso.other\" => true"))
        XCTAssertNil(LaunchAgent.disabledState(for: LaunchAgent.label, in: "\"com.kqw8.inverso\" => true-ish"))
    }

    func testMissingDisabledOverrideDefaultsToEnabledOnlyAfterValidQuery() throws {
        XCTAssertFalse(try LaunchAgent.disabledOverride { _ in (0, "\n\tdisabled services = {\n\t}\n") })
        XCTAssertThrowsError(try LaunchAgent.disabledOverride { _ in (1, "Operation not permitted") })
        XCTAssertThrowsError(try LaunchAgent.disabledOverride { _ in (0, "") })
        XCTAssertThrowsError(try LaunchAgent.disabledOverride { _ in (0, "disabled services = {\n\"com.kqw8.inverso\" => unknown\n}") })
    }

    func testDisableLoginDoesNotTreatFailedQueryAsDisabled() {
        var commands: [String] = []
        XCTAssertThrowsError(try LaunchAgent.setLoginEnabled(false) { arguments in
            commands.append(arguments[0])
            return arguments[0] == "disable" ? (0, "") : (1, "Operation not permitted")
        })
        XCTAssertEqual(commands, ["disable", "print-disabled"])
    }
}
