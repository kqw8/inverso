import Foundation

public enum LaunchAgent {
    public static let label = "com.kqw8.inverso"

    public struct ServiceStatus {
        public let isLoaded: Bool
        public let pid: Int32?
        public let state: String?

        // A running process does not necessarily have permission or an active event tap.
        public var isRunning: Bool { isLoaded && pid != nil && state == "running" }
    }

    public struct Failure: LocalizedError, CustomStringConvertible {
        public let description: String
        public var errorDescription: String? { description }
    }

    typealias CommandRunner = ([String]) -> (status: Int32, output: String)

    private static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    public static var plistURL: URL { plistURL(in: homeDirectory) }
    private static var domainTarget: String { "gui/\(getuid())" }
    private static var serviceTarget: String { "\(domainTarget)/\(label)" }

    private static func plistURL(in home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static func logPaths() -> [String] { logPaths(in: homeDirectory) }

    private static func logPaths(in home: URL) -> [String] {
        let directory = home.appendingPathComponent("Library/Logs")
        return ["inverso.out.log", "inverso.err.log"].map { directory.appendingPathComponent($0).path }
    }

    public static func plistContents(executablePath: String, smoothingEnabled: Bool = true) -> String {
        plistContents(executablePath: executablePath, smoothingEnabled: smoothingEnabled, homeDirectory: homeDirectory)
    }

    static func plistContents(executablePath: String, smoothingEnabled: Bool = true, homeDirectory: URL) -> String {
        let logs = logPaths(in: homeDirectory)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "--daemon"] + (smoothingEnabled ? [] : ["--no-smooth"]),
            "RunAtLoad": true,
            "KeepAlive": true,
            // This synchronous input filter must not be background-throttled.
            "ProcessType": "Interactive",
            "StandardOutPath": logs[0],
            "StandardErrorPath": logs[1],
        ]
        // This dictionary contains only supported plist types. Serialization escapes paths.
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    public static func writePlist(executablePath: String, smoothingEnabled: Bool = true) throws -> URL {
        try writePlist(executablePath: executablePath, smoothingEnabled: smoothingEnabled, homeDirectory: homeDirectory)
    }

    @discardableResult
    static func writePlist(executablePath: String, smoothingEnabled: Bool = true, homeDirectory: URL) throws -> URL {
        let url = plistURL(in: homeDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDirectory.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
        try plistContents(executablePath: executablePath, smoothingEnabled: smoothingEnabled, homeDirectory: homeDirectory)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Read only, so a malformed existing configuration is rejected before unload.
    public static func smoothingEnabled() throws -> Bool {
        try smoothingEnabled(homeDirectory: homeDirectory)
    }

    static func smoothingEnabled(homeDirectory: URL) throws -> Bool {
        let url = plistURL(in: homeDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return true
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label,
              let arguments = plist["ProgramArguments"] as? [String],
              let executable = arguments.first, !executable.isEmpty,
              let options = try? CLIOptions(arguments: Array(arguments.dropFirst())),
              case .daemon(let enabled) = options else {
            throw Failure(description: "Cannot read the smoothing setting from \(url.path). Reinstall with --smooth or --no-smooth.")
        }
        return enabled
    }

    @discardableResult
    public static func removePlist() -> Bool {
        do {
            if plistExists() {
                try FileManager.default.removeItem(at: plistURL)
            }
            return !plistExists()
        } catch {
            return false
        }
    }

    public static func plistExists() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public static func serviceStatus() throws -> ServiceStatus { try serviceStatus(using: launchctl) }

    static func serviceStatus(using run: CommandRunner) throws -> ServiceStatus {
        let arguments = ["print", serviceTarget]
        let result = run(arguments)
        if result.status == 113 && result.output.contains("Could not find service \"\(label)\" in domain") {
            return ServiceStatus(isLoaded: false, pid: nil, state: nil)
        }
        try requireSuccess(result, arguments: arguments)

        // launchctl print is diagnostic output, not a stable API. Read only known
        // top-level fields; unknown formatting leaves the process state unknown.
        var pid: Int32?
        var state: String?
        for line in result.output.split(separator: "\n") {
            if line.hasPrefix("\tpid = "), let value = Int32(line.dropFirst("\tpid = ".count)), value > 0 {
                pid = value
            } else if line.hasPrefix("\tstate = ") {
                state = String(line.dropFirst("\tstate = ".count))
            }
        }
        return ServiceStatus(isLoaded: true, pid: pid, state: state)
    }

    public static func loginEnabled() throws -> Bool {
        guard plistExists() else { return false }
        return try !disabledOverride(using: launchctl)
    }

    public static func loadService() throws { try loadService(using: launchctl) }

    static func loadService(using run: CommandRunner) throws {
        if try serviceStatus(using: run).isLoaded { return }
        try execute(["bootstrap", domainTarget, plistURL.path], using: run)
        guard try serviceStatus(using: run).isLoaded else {
            throw Failure(description: "launchctl bootstrap succeeded, but the service is not loaded.")
        }
    }

    public static func unloadService() throws { try unloadService(using: launchctl) }

    static func unloadService(using run: CommandRunner) throws {
        if try !serviceStatus(using: run).isLoaded { return }
        try execute(["bootout", serviceTarget], using: run)
        guard try !serviceStatus(using: run).isLoaded else {
            throw Failure(description: "launchctl bootout succeeded, but the service is still loaded.")
        }
    }

    public static func restartService() throws { try restartService(using: launchctl) }

    static func restartService(using run: CommandRunner) throws {
        try execute(["kickstart", "-k", serviceTarget], using: run)
        guard try serviceStatus(using: run).isLoaded else {
            throw Failure(description: "launchctl kickstart succeeded, but the service is not loaded.")
        }
    }

    public static func setLoginEnabled(_ enabled: Bool) throws {
        try setLoginEnabled(enabled, using: launchctl)
    }

    static func setLoginEnabled(_ enabled: Bool, using run: CommandRunner) throws {
        try execute([enabled ? "enable" : "disable", serviceTarget], using: run)
        guard try disabledOverride(using: run) == !enabled else {
            throw Failure(description: "launchctl did not apply the requested start-at-login setting.")
        }
    }

    static func disabledOverride(using run: CommandRunner) throws -> Bool {
        let arguments = ["print-disabled", domainTarget]
        let result = run(arguments)
        try requireSuccess(result, arguments: arguments)
        let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "disabled services = {", lines.last == "}" else {
            throw Failure(description: "Unrecognized launchctl print-disabled output: \(result.output)")
        }
        if let disabled = disabledState(for: label, in: result.output) { return disabled }
        // No override means enabled. An unrecognized override is not the same as absence.
        if lines.contains(where: { $0.hasPrefix("\"\(label)\"") }) {
            throw Failure(description: "Unrecognized launchctl login setting for \(label): \(result.output)")
        }
        return false
    }

    public static func disabledState(for label: String, in output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "\"\(label)\"" else { continue }
            switch parts[1].trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "disabled": return true
            case "false", "enabled": return false
            default: return nil
            }
        }
        return nil
    }

    private static func execute(_ arguments: [String], using run: CommandRunner) throws {
        try requireSuccess(run(arguments), arguments: arguments)
    }

    private static func requireSuccess(_ result: (status: Int32, output: String), arguments: [String]) throws {
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: "launchctl \(arguments.joined(separator: " ")) failed (exit \(result.status))\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }

    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "failed to run launchctl: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
