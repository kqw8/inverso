import Foundation

/// Used only on the event run loop that owns the smoothing state.
protocol SmoothingFrameDriving: AnyObject {
    var isRunning: Bool { get }
    func start(_ onFrame: @escaping () -> Void) -> Bool
    func stop()
}

/// Schedules frames only while smoothing has pending motion. The consumer uses
/// monotonic elapsed time; timer delivery itself is not a latency guarantee.
final class RunLoopSmoothingDriver: SmoothingFrameDriving {
    private let owner = Thread.current
    private let runLoop = RunLoop.current
    private let interval: TimeInterval
    private var timer: Timer?
    private var onFrame: (() -> Void)?

    init(interval: TimeInterval = 1.0 / 120.0) {
        precondition(interval.isFinite && interval > 0)
        self.interval = interval
    }

    var isRunning: Bool {
        precondition(Thread.current === owner)
        return timer?.isValid == true
    }

    /// Repeated starts retain the current cadence and callback. A callback that
    /// references its owning controller should capture that controller weakly.
    func start(_ onFrame: @escaping () -> Void) -> Bool {
        precondition(Thread.current === owner)
        if isRunning { return true }
        self.onFrame = onFrame
        let timer = Timer(fire: Date(timeIntervalSinceNow: interval), interval: interval,
                          repeats: true) { [weak self] _ in
            autoreleasepool { self?.onFrame?() }
        }
        self.timer = timer
        runLoop.add(timer, forMode: .common)
        return true
    }

    func stop() {
        precondition(Thread.current === owner)
        timer?.invalidate()
        timer = nil
        onFrame = nil
    }

    deinit { timer?.invalidate() }
}
