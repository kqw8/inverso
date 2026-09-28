/// Parse the complete command before any service or permission operation runs.
public enum CLIOptions: Equatable {
    /// nil preserves an existing installation's setting, defaulting to true.
    case install(smoothingEnabled: Bool?)
    case daemon(smoothingEnabled: Bool)
    case speed(multiplier: Double?)
    case uninstall, start, stop, status, permission, help, version

    public struct UsageError: Error, CustomStringConvertible {
        public let description: String
    }

    public init(arguments: [String]) throws {
        guard let command = arguments.first else {
            self = .help
            return
        }
        if command == "install" || command == "--daemon" {
            let smoothing: Bool?
            switch Array(arguments.dropFirst()) {
            case []: smoothing = nil
            case ["--smooth"]: smoothing = true
            case ["--no-smooth"]: smoothing = false
            default:
                throw UsageError(description: "\(command) accepts only --smooth or --no-smooth.")
            }
            self = command == "install" ? .install(smoothingEnabled: smoothing)
                : .daemon(smoothingEnabled: smoothing ?? true)
            return
        }
        if command == "speed" {
            guard arguments.count <= 2 else {
                throw UsageError(description: "speed accepts at most one multiplier from 0.25 to 4.")
            }
            if arguments.count == 1 {
                self = .speed(multiplier: nil)
            } else {
                guard let multiplier = Double(arguments[1]),
                      (try? ScrollSettings(speedMultiplier: multiplier)) != nil else {
                    throw UsageError(description: "Scroll speed must be a finite number from 0.25 to 4.")
                }
                self = .speed(multiplier: multiplier)
            }
            return
        }
        guard arguments.count == 1 else {
            throw UsageError(description: "Unexpected arguments after \(command).")
        }
        switch command {
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
