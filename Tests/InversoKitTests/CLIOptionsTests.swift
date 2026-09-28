import InversoKit
import XCTest

final class CLIOptionsTests: XCTestCase {
    func testAcceptsSpeedQueryAndValidMultiplier() throws {
        XCTAssertEqual(try CLIOptions(arguments: ["speed"]), .speed(multiplier: nil))
        for multiplier in [0.25, 1, 1.5, 4] {
            XCTAssertEqual(try CLIOptions(arguments: ["speed", String(multiplier)]), .speed(multiplier: multiplier))
        }
    }

    func testRejectsInvalidSpeedValuesBeforeDispatch() {
        for arguments in [["speed", ""], ["speed", "fast"], ["speed", "nan"], ["speed", "inf"],
                          ["speed", "-inf"], ["speed", "0"], ["speed", "-1"], ["speed", "0.249"],
                          ["speed", "4.001"], ["speed", "1.5", "extra"], ["speed", "--smooth"],
                          ["install", "--speed", "1.5"], ["--daemon", "--speed", "1.5"]] {
            XCTAssertThrowsError(try CLIOptions(arguments: arguments), "\(arguments)")
        }
    }

    func testInstallDistinguishesPreservingTheSettingFromExplicitChanges() throws {
        XCTAssertEqual(try CLIOptions(arguments: ["install"]), .install(smoothingEnabled: nil))
        XCTAssertEqual(try CLIOptions(arguments: ["install", "--smooth"]), .install(smoothingEnabled: true))
        XCTAssertEqual(try CLIOptions(arguments: ["install", "--no-smooth"]), .install(smoothingEnabled: false))
    }

    func testDaemonDefaultsToSmoothingAndAcceptsExplicitOverrides() throws {
        XCTAssertEqual(try CLIOptions(arguments: ["--daemon"]), .daemon(smoothingEnabled: true))
        XCTAssertEqual(try CLIOptions(arguments: ["--daemon", "--smooth"]), .daemon(smoothingEnabled: true))
        XCTAssertEqual(try CLIOptions(arguments: ["--daemon", "--no-smooth"]), .daemon(smoothingEnabled: false))
    }

    func testRecognizesExistingCommandsAndAliases() throws {
        let cases: [([String], CLIOptions)] = [
            ([], .help), (["help"], .help), (["--help"], .help), (["-h"], .help),
            (["--version"], .version), (["-v"], .version),
            (["start"], .start), (["stop"], .stop), (["status"], .status),
            (["permission"], .permission), (["uninstall"], .uninstall),
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(try CLIOptions(arguments: arguments), expected, "\(arguments)")
        }
    }

    func testRejectsEveryUnexpectedArgumentBeforeDispatch() {
        let cases = [
            ["unknown"], ["--no-smooth"], ["install", "--wat"], ["--daemon", "--wat"],
            ["install", "--smooth", "--no-smooth"], ["--daemon", "--no-smooth", "--smooth"],
            ["install", "--no-smooth", "--no-smooth"], ["--daemon", "--smooth", "extra"],
            ["status", "junk"], ["start", "--no-smooth"], ["stop", "--smooth"],
            ["uninstall", "junk"], ["permission", "junk"], ["help", "junk"], ["--version", "junk"],
        ]
        for arguments in cases {
            XCTAssertThrowsError(try CLIOptions(arguments: arguments), "\(arguments)") { error in
                XCTAssertFalse(String(describing: error).isEmpty)
            }
        }
    }
}
