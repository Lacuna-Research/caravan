import Foundation
import IRCProtocol

/// How fast the client is allowed to talk.
///
/// **A delay, never a drop.** This paces lines the *user typed*, and a sentence thrown away
/// to protect a connection is worse than the disconnect it prevents — which is the whole
/// difference between this and ``CTCPThrottle``, whose job is to decide whether to answer a
/// stranger at all. The two compose deliberately; `BUILD-LOG.md` says why.
///
/// The numbers are irssi's, and have been right on every network for twenty years: five
/// lines back to back, then one every two seconds. A person typing never meets the limit; a
/// paste of thirty lines does, which is exactly the case that earns `Excess Flood`.
public struct SendPacer: Sendable {
    /// How many lines may leave back to back.
    public let burst: Int
    /// How long one line's worth of allowance takes to come back.
    public let recovery: Duration

    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant

    public init(
        burst: Int = 5,
        recovery: Duration = .seconds(2),
        now: ContinuousClock.Instant
    ) {
        self.burst = burst
        self.recovery = recovery
        self.tokens = Double(burst)
        self.lastRefill = now
    }

    /// How long the next line must wait, and `nil` for "it may go now".
    ///
    /// Asking rather than sleeping keeps this a value type: the caller owns the waiting, so
    /// a test can advance an instant instead of a suite spending two seconds proving that a
    /// two-second delay is two seconds.
    ///
    /// **Called once per line, in order, by a single drain** — it hands out the allowance as
    /// it answers, so asking twice without having waited in between describes a caller that
    /// sends two lines at once, which is the thing this exists to stop.
    public mutating func delayForNextSend(at now: ContinuousClock.Instant) -> Duration? {
        refill(to: now)
        if tokens >= 1 {
            tokens -= 1
            return nil
        }
        // The bucket is empty: the wait is whatever is left of one token's recovery.
        let missing = 1 - tokens
        let wait = recovery * missing
        tokens = 0
        lastRefill = now + wait
        return wait
    }

    private mutating func refill(to now: ContinuousClock.Instant) {
        guard now > lastRefill else { return }
        let elapsed = lastRefill.duration(to: now)
        tokens = min(Double(burst), tokens + elapsed / recovery)
        lastRefill = now
    }
}

extension IRCMessage {
    /// Whether this line goes out ahead of anything queued, and without spending allowance.
    ///
    /// **Two exemptions, each with a reason, and no general priority concept.** A queued
    /// `PONG` is a ping timeout — the limiter would cause the very disconnect it exists to
    /// prevent — and registration is the one part of a session every server is already
    /// lenient about, so pacing it only delays getting online. A third caller wanting to
    /// jump the queue is a design conversation, not a new case here.
    ///
    /// **The registration half expires with registration.** `NICK` is a registration line
    /// for the first second of a session and an ordinary command forever after, and a `/nick`
    /// loop is a flood like any other — so the exemption is asked with `isRegistered` rather
    /// than answered from the verb alone.
    func bypassesPacing(isRegistered: Bool) -> Bool {
        // Keeping the connection alive, and leaving. Neither can wait behind a paste.
        for verb in ["PONG", "PING", "QUIT"] where command.isVerb(verb) { return true }
        guard !isRegistered else { return false }
        for verb in ["NICK", "USER", "PASS", "CAP", "AUTHENTICATE"] where command.isVerb(verb) {
            return true
        }
        return false
    }
}
