/// Exponential backoff with jitter and a ceiling.
///
/// A pure value with a pure function, so the schedule is tested by arithmetic rather
/// than by waiting for it. Jitter is a parameter rather than a call to a random
/// generator inside, for the same reason.
public struct BackoffPolicy: Sendable, Equatable {
    /// Delay before the first retry.
    public var initialDelay: Duration
    /// Multiplier applied per attempt.
    public var multiplier: Double
    /// Ceiling, before jitter. Reconnecting to an IRC network is cheap for us and not
    /// for the server, so this exists to stop a long outage turning into a flood.
    public var maximumDelay: Duration
    /// Fraction of the delay to spread the jitter over, e.g. `0.2` for ±20%.
    ///
    /// Without it, every client disconnected by the same netsplit comes back in the same
    /// second, which is how a recovering server gets knocked over a second time.
    public var jitterFraction: Double

    public init(
        initialDelay: Duration = .seconds(2),
        multiplier: Double = 2,
        maximumDelay: Duration = .seconds(300),
        jitterFraction: Double = 0.2
    ) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
        self.jitterFraction = jitterFraction
    }

    /// Delay before `attempt`, which counts from 1.
    ///
    /// - Parameter randomness: A value in `0..<1`. Injected so the schedule is testable;
    ///   `0.5` is the unjittered delay, `0` and `1` its extremes.
    public func delay(forAttempt attempt: Int, randomness: Double) -> Duration {
        guard attempt >= 1 else { return .zero }
        let base = min(
            initialDelay.seconds * multiplier.raised(toPowerOf: attempt - 1),
            maximumDelay.seconds
        )
        let spread = base * jitterFraction * (2 * randomness.clamped(to: 0...1) - 1)
        return .seconds(max(0, base + spread))
    }

    /// Delay before `attempt`, jittered with a fresh random value.
    public func delay(forAttempt attempt: Int) -> Duration {
        delay(forAttempt: attempt, randomness: Double.random(in: 0..<1))
    }
}

extension Duration {
    /// Seconds as a `Double`. `Duration` has no floating-point conversion of its own, and
    /// backoff arithmetic is inherently fractional.
    var seconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

    /// Integer exponentiation. The attempt counter is small and whole, so this avoids
    /// pulling in Foundation for `pow`.
    fileprivate func raised(toPowerOf exponent: Int) -> Double {
        guard exponent > 0 else { return 1 }
        return (0..<exponent).reduce(1.0) { product, _ in product * self }
    }
}
