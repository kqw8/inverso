import Darwin
import Foundation
import InversoKit

let inversoVersion = "0.3.1"

func currentExecutablePath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buffer, &size) == 0 {
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
    return CommandLine.arguments.first ?? "inverso"
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func usage() {
    print("""
    inverso \(inversoVersion)

    Usage:
      inverso install [--smooth | --no-smooth]
                           Install and start the service, enabled at login
      inverso uninstall    Stop the service and remove LaunchAgent/logs
      inverso start        Start the background service
      inverso stop         Stop the background service until next login/start
      inverso status       Show service and permission state
      inverso speed [factor]
                           Show or save smooth-scroll speed (0.25...4; 1.0x is normal)
      inverso permission   Ask macOS for Accessibility permission
      inverso --daemon [--smooth | --no-smooth]
                           Run the background event tap

    Smoothing defaults to on. Bare install preserves the existing smoothing setting.
    Use install --no-smooth for immediate wheel reversal, or install --smooth to enable smoothing.
    Speed changes normally apply to a running service in about 5 seconds; no restart is needed.
    """)
}

func install(smoothingEnabled requested: Bool?) {
    let smoothingEnabled: Bool
    do {
        // Read a saved preference before unloading; explicit flags can replace
        // an invalid old configuration without having to read its setting.
        smoothingEnabled = try requested ?? LaunchAgent.smoothingEnabled()
        try LaunchAgent.unloadService()
        try LaunchAgent.writePlist(executablePath: currentExecutablePath(), smoothingEnabled: smoothingEnabled)
        try LaunchAgent.setLoginEnabled(true)
        try LaunchAgent.loadService()
    } catch {
        printErr("❌ Install failed: \(error)")
        exit(1)
    }
    print("✅ Inverso installed; background service loaded.")
    print("   • Start at login: on")
    print("   • Smooth scrolling: \(smoothingEnabled ? "on" : "off")")
    print("   Run inverso status to check the process and scroll event tap.")
}

func uninstall() {
    do {
        try LaunchAgent.unloadService()
        try LaunchAgent.setLoginEnabled(false)
    } catch {
        printErr("❌ Uninstall incomplete: \(error)")
        exit(1)
    }
    guard LaunchAgent.removePlist() else {
        printErr("❌ Service stopped, but could not remove LaunchAgent plist.")
        exit(1)
    }
    do {
        for path in LaunchAgent.logPaths() where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    } catch {
        printErr("❌ Service and LaunchAgent removed, but could not remove all logs: \(error)")
        exit(1)
    }
    print("✅ Inverso stopped and removed its LaunchAgent/logs.")
    print("   Binary still lives at: \(currentExecutablePath())")
}

func start() {
    do {
        if !LaunchAgent.plistExists() {
            try LaunchAgent.writePlist(executablePath: currentExecutablePath())
        }
        try LaunchAgent.setLoginEnabled(true)
        if try LaunchAgent.serviceStatus().isLoaded {
            try LaunchAgent.restartService()
        } else {
            try LaunchAgent.loadService()
        }
    } catch {
        printErr("❌ Start failed: \(error)")
        exit(1)
    }
    print("✅ Inverso background service loaded; run inverso status to check the event tap.")
}

func stop() {
    do {
        try LaunchAgent.unloadService()
    } catch {
        printErr("❌ Stop failed: \(error)")
        exit(1)
    }
    print("✅ Inverso background service stopped until next login/start.")
}

func status() {
    print("inverso \(inversoVersion) — status")
    print("")
    print("Input permission:")
    print("  • Accessibility (this process): \(Accessibility.isTrusted ? "granted" : "missing")")
    print("")
    print("Residency / autostart:")
    var queryFailed = false
    do {
        let service = try LaunchAgent.serviceStatus()
        if !service.isLoaded {
            print("  • Background service: not loaded")
        } else if service.isRunning, let pid = service.pid {
            print("  • Background service: running (PID \(pid))")
            let tapState = EventTapService.hasEnabledScrollTap(processID: pid)
            print("  • Scroll event tap:   \(tapState.map { $0 ? "enabled" : "not enabled" } ?? "unknown")")
            if tapState == nil { queryFailed = true }
        } else {
            print("  • Background service: loaded (state: \(service.state ?? "unknown"), no confirmed running process)")
        }
    } catch {
        print("  • Background service: unknown")
        printErr("   \(error)")
        queryFailed = true
    }
    do {
        print("  • Start at login:     \(try LaunchAgent.loginEnabled() ? "on" : "off")")
    } catch {
        print("  • Start at login:     unknown")
        printErr("   \(error)")
        queryFailed = true
    }
    if LaunchAgent.plistExists() {
        do {
            print("  • Smooth scrolling (configured): \(try LaunchAgent.smoothingEnabled() ? "on" : "off")")
        } catch {
            print("  • Smooth scrolling (configured): unknown")
            printErr("   \(error)")
            queryFailed = true
        }
    } else {
        print("  • Smooth scrolling (configured): not installed (default: on)")
    }
    do {
        print("  • Scroll speed (configured): \(try ScrollSettingsStore.load().speedMultiplier)x")
    } catch {
        print("  • Scroll speed (configured): unknown")
        printErr("   \(error)")
        queryFailed = true
    }
    print("")
    print("LaunchAgent:")
    print("  • \(LaunchAgent.plistURL.path)")
    if queryFailed { exit(1) }
}

func speed(multiplier: Double?) {
    do {
        if let multiplier {
            try ScrollSettingsStore.save(ScrollSettings(speedMultiplier: multiplier))
            print("Smooth-scroll speed saved: \(multiplier)x")
            print("A running service applies the setting at its next health check (normally about 5 seconds).")
        } else {
            print("Smooth-scroll speed: \(try ScrollSettingsStore.load().speedMultiplier)x (1.0x is normal)")
        }
    } catch {
        printErr("inverso: Could not \(multiplier == nil ? "read" : "save") scroll speed: \(error)")
        exit(1)
    }
}

func requestPermission() {
    if Accessibility.isTrusted {
        print("✅ Accessibility permission granted.")
        return
    }

    _ = Accessibility.requestPrompt()
    print("⏳ Waiting for Accessibility approval for:")
    print("   \(currentExecutablePath())")
    print("   Keep this command running while approving Inverso in System Settings.")

    let deadline = Date().addingTimeInterval(120)
    var nextReminder = Date().addingTimeInterval(15)
    while Date() < deadline {
        if Accessibility.isTrusted {
            print("✅ Accessibility permission granted.")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if Date() >= nextReminder {
            print("   Still waiting...")
            nextReminder = Date().addingTimeInterval(15)
        }
    }

    printErr("⚠️  Accessibility permission is still missing.")
    printErr("   If Inverso is not listed, add this binary manually:")
    printErr("   \(currentExecutablePath())")
    exit(1)
}

let command: CLIOptions
do {
    command = try CLIOptions(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    printErr("inverso: \(error)")
    usage()
    exit(2)
}

switch command {
case .daemon(let smoothingEnabled):
    do {
        try DaemonRunner(smoothingEnabled: smoothingEnabled).run()
    } catch {
        printErr("inverso: \(error)")
        exit(1)
    }
case .install(let smoothingEnabled):
    install(smoothingEnabled: smoothingEnabled)
case .uninstall:
    uninstall()
case .start:
    start()
case .stop:
    stop()
case .status:
    status()
case .speed(let multiplier):
    speed(multiplier: multiplier)
case .permission:
    requestPermission()
case .version:
    print("inverso \(inversoVersion)")
case .help:
    usage()
}
