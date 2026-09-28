/// Parse the complete command before any service or permission operation runs.
public enum CLIOptions: Equatable {
    case install, daemon, uninstall, start, stop, status, permission, help, version

    public struct UsageError: Error, CustomStringConvertible {
        public let description: String
    }

    public init(arguments: [String]) throws {
        guard let command = arguments.first else {
            self = .help
            return
        }
        // 0.3 LaunchAgents still pass a smoothing flag; the daemon must start anyway.
        if command == "--daemon", arguments.count == 2, ["--smooth", "--no-smooth"].contains(arguments[1]) {
            self = .daemon
            return
        }
        guard arguments.count == 1 else {
            throw UsageError(description: "Unexpected arguments after \(command).")
        }
        switch command {
        case "install": self = .install
        case "--daemon": self = .daemon
        case "uninstall": self = .uninstall
        case "start": self = .start
        case "stop": self = .stop
        case "status": self = .status
        case "permission": self = .permission
        case "help", "--help", "-h": self = .help
        case "--version", "-v": self = .version
        default: throw UsageError(description: "Unknown command: \(command).")
        }
    }
}
