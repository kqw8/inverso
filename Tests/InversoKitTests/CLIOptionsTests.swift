import InversoKit
import XCTest

final class CLIOptionsTests: XCTestCase {
    func testRecognizesCommandsAndAliases() throws {
        let cases: [([String], CLIOptions)] = [
            ([], .help), (["help"], .help), (["--help"], .help), (["-h"], .help),
            (["--version"], .version), (["-v"], .version), (["install"], .install),
            (["--daemon"], .daemon), (["start"], .start), (["stop"], .stop),
            (["status"], .status), (["permission"], .permission), (["uninstall"], .uninstall),
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(try CLIOptions(arguments: arguments), expected, "\(arguments)")
        }
    }

    func testDaemonStillStartsFromAnOlderLaunchAgent() throws {
        // 0.3 LaunchAgents pass a smoothing flag. Rejecting it would leave the wheel unreversed.
        XCTAssertEqual(try CLIOptions(arguments: ["--daemon", "--no-smooth"]), .daemon)
        XCTAssertEqual(try CLIOptions(arguments: ["--daemon", "--smooth"]), .daemon)
    }

    func testRejectsRemovedAndUnexpectedArgumentsBeforeDispatch() {
        let cases = [
            ["unknown"], ["speed"], ["speed", "1.5"], ["--no-smooth"], ["install", "--smooth"],
            ["install", "--no-smooth"], ["install", "--wat"], ["--daemon", "--wat"],
            ["--daemon", "--no-smooth", "--smooth"], ["status", "junk"], ["start", "--no-smooth"],
            ["stop", "--smooth"], ["uninstall", "junk"], ["permission", "junk"], ["help", "junk"],
            ["--version", "junk"],
        ]
        for arguments in cases {
            XCTAssertThrowsError(try CLIOptions(arguments: arguments), "\(arguments)") { error in
                XCTAssertFalse(String(describing: error).isEmpty)
            }
        }
    }
}
