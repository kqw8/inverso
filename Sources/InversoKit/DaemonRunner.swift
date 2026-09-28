import Foundation

protocol EventTapControlling: AnyObject {
    var isRunning: Bool { get }
    var disableStats: TapDisableStats { get }
    func start() throws
    func stop()
    func setScrollSpeed(_ multiplier: Double)
}

public final class DaemonRunner {
    private let service: EventTapControlling
    private let permissionGranted: () -> Bool
    private let requestPermission: () -> Void
    private let report: (String) -> Void
    private let loadSettings: (() throws -> ScrollSettings)?
    private var healthTimer: Timer?
    private var instanceLock: SingleInstanceLock?
    private var promptedForPermission = false
    private var lastReport: String?
    private var lastAppliedSpeed: Double?
    private var lastSettingsError: String?
    private var reportedDisables = TapDisableStats()

    public convenience init(smoothingEnabled: Bool = true) {
        self.init(
            service: EventTapService(smoothingEnabled: smoothingEnabled),
            permissionGranted: { Accessibility.isTrusted },
            requestPermission: { _ = Accessibility.requestPrompt() },
            report: { FileHandle.standardError.write(Data(DaemonRunner.logLine($0, date: Date()).utf8)) },
            loadSettings: { try ScrollSettingsStore.load() }
        )
    }

    init(service: EventTapControlling, permissionGranted: @escaping () -> Bool,
         requestPermission: @escaping () -> Void, report: @escaping (String) -> Void,
         loadSettings: (() throws -> ScrollSettings)? = nil) {
        self.service = service
        self.permissionGranted = permissionGranted
        self.requestPermission = requestPermission
        self.report = report
        self.loadSettings = loadSettings
    }

    public func run() throws -> Never {
        precondition(Thread.isMainThread)
        // launchd redirects stderr to a file: wait there, but fail fast in a terminal.
        instanceLock = try SingleInstanceLock(url: SingleInstanceLock.defaultURL,
                                              waitIfHeld: isatty(STDERR_FILENO) == 0) {
            report("another inverso daemon is already running; waiting for it to exit.")
        }
        refresh()
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 1.0
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime(self) {
            RunLoop.main.run()
        }
        fatalError("run loop exited unexpectedly")
    }

    // Also called after a successful start: permission and tap validity can change.
    func refresh() {
        refreshSettings()
        guard permissionGranted() else {
            service.stop()
            if !promptedForPermission {
                promptedForPermission = true
                requestPermission()
            }
            reportChange("Accessibility permission is missing; waiting for macOS approval.")
            return
        }

        do {
            if !service.isRunning { try service.start() }
            reportChange("scroll event tap is ready.")
        } catch {
            reportChange("\(error); will retry.")
        }
        reportTapDisables()
    }

    private func reportTapDisables() {
        let stats = service.disableStats
        let count = stats.timeouts + stats.userInput - reportedDisables.timeouts - reportedDisables.userInput
        guard count > 0 else { return }
        reportedDisables = stats
        let last = stats.last.map { " (last at \(Self.timestamp($0)))" } ?? ""
        // Not reportChange: this line must not make the next state message repeat.
        report("macOS disabled the scroll event tap \(count) \(count == 1 ? "time" : "times")\(last); "
            + "it was re-enabled immediately. Since start: \(stats.timeouts) timeout(s), "
            + "\(stats.userInput) user-input.")
    }

    private func refreshSettings() {
        guard let loadSettings else { return }
        do {
            // Filesystem work belongs to the control thread, never a scroll or
            // animation callback. Keep the last valid speed on read/parse failure.
            let settings = try loadSettings()
            if settings.speedMultiplier != lastAppliedSpeed {
                service.setScrollSpeed(settings.speedMultiplier)
                lastAppliedSpeed = settings.speedMultiplier
            }
            lastSettingsError = nil
        } catch {
            let message = "could not load scroll settings: \(error); keeping the current speed."
            if lastSettingsError != message {
                lastSettingsError = message
                report(message)
            }
        }
    }

    /// A local timestamp lets a log line be matched to a noticed stall.
    static func logLine(_ message: String, date: Date) -> String {
        "\(timestamp(date)) inverso: \(message)\n"
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: .current))
    }

    private func reportChange(_ message: String) {
        guard lastReport != message else { return }
        lastReport = message
        report(message)
    }

    deinit {
        healthTimer?.invalidate()
        service.stop()
    }
}
