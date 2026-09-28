import Foundation

/// A constant-space, time-based scroll response. Call from one owning thread.
/// Distance is conserved except when reversal, reset, or a stale clock gap
/// deliberately discards motion that has not yet been returned to the caller.
struct ScrollSmoother {
    static let maximumDistance = 1_000_000_000.0

    private let responseTime: Double
    private let staleInterval: Double
    private var remaining = 0.0
    // Velocity divided by omega avoids overflow with very short response times.
    private var normalizedVelocity = 0.0
    private var pendingOutput = 0.0
    private var lastTime: Double?
    private var lastInputTime: Double?

    init(responseTime: Double = 0.08, staleInterval: Double = 0.5) {
        self.responseTime = responseTime.isFinite && responseTime > 0 ? responseTime : 0.08
        self.staleInterval = staleInterval.isFinite && staleInterval > 0 ? staleInterval : 0.5
    }

    var isActive: Bool { remaining != 0 || pendingOutput != 0 }

    /// Rejects malformed or excessively large input without changing valid motion.
    /// Zero input is ignored and does not extend the current response.
    @discardableResult
    mutating func enqueue(delta: Double, at time: Double) -> Bool {
        guard delta.isFinite, time.isFinite, delta != 0,
              abs(delta) <= Self.maximumDistance else { return false }

        var candidate = self
        let outstanding = candidate.remaining != 0 ? candidate.remaining : candidate.pendingOutput
        if outstanding != 0 && outstanding.sign != delta.sign {
            // Reverse immediately, including output generated between frame ticks.
            candidate.reset()
        }
        candidate.integrate(at: time)
        let outstandingDistance = abs(candidate.remaining) + abs(candidate.pendingOutput)
        guard outstandingDistance <= Self.maximumDistance - abs(delta) else { return false }
        candidate.remaining += delta
        candidate.lastTime = time
        candidate.lastInputTime = time
        self = candidate
        return true
    }

    /// Returns distance accumulated since the preceding advance, including any
    /// elapsed motion recorded by enqueue between frame ticks.
    mutating func advance(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        integrate(at: time)
        let output = pendingOutput
        pendingOutput = 0
        if remaining == 0 { reset() }
        return output
    }

    mutating func reset() {
        remaining = 0
        normalizedVelocity = 0
        pendingOutput = 0
        lastTime = nil
        lastInputTime = nil
    }

    private mutating func integrate(at time: Double) {
        guard let previous = lastTime, let inputTime = lastInputTime else { return }
        let elapsed = time - previous
        guard elapsed >= 0, elapsed < staleInterval else {
            reset()
            return
        }
        lastTime = time
        // Compare to the deadline directly: subtracting a large clock epoch can
        // round an exact deadline to an elapsed value just below responseTime.
        if time >= inputTime + responseTime {
            // At omega * responseTime = 8, only about 0.3% of a single impulse
            // remains. Settle it exactly instead of running an infinite tail.
            pendingOutput += remaining
            remaining = 0
            normalizedVelocity = 0
            return
        }
        guard elapsed > 0, remaining != 0 else { return }

        // Exact critical-damping solution, not a frame-dependent approximation.
        // New same-direction input adds distance without resetting velocity.
        let scaledTime = 8 * (elapsed / responseTime)
        let decay = exp(-scaledTime)
        let coefficient = remaining - normalizedVelocity
        let next = (remaining + coefficient * scaledTime) * decay
        // Floating-point cancellation at tiny intervals must not reverse a drip.
        let nextRemaining = remaining > 0 ? min(remaining, max(0, next)) : max(remaining, min(0, next))
        normalizedVelocity = (normalizedVelocity + coefficient * scaledTime) * decay
        pendingOutput += remaining - nextRemaining
        remaining = nextRemaining
    }
}
