import IRCProtocol

/// What this client answers a CTCP request with.
///
/// A table, and pure: given a request and the three facts that vary — the version
/// string, the real name and the time — the answer is fixed. Nothing here reaches for a
/// clock or a socket, so the whole set is testable as a table rather than by flooding a
/// live connection.
///
/// **Silence is the answer for anything not listed.** No `ERRMSG`, which the older
/// specs suggest: replying to an unknown keyword is a free amplifier for whoever picks
/// the keyword, and it tells them exactly which client they are talking to.
public enum CTCPReplies {
    /// The keywords answered, in the order `CLIENTINFO` lists them.
    ///
    /// `ACTION` is in the list because it is a CTCP this client understands, and
    /// `CLIENTINFO` is a question about what is understood — but it is never *answered*,
    /// which is the distinction the responder below enforces.
    public static let supported = [
        "ACTION", "CLIENTINFO", "FINGER", "PING", "TIME", "USERINFO", "VERSION",
    ]

    /// The reply to a request, or `nil` for one this client does not answer.
    ///
    /// The reply's keyword is always the request's, because that is how the sender
    /// matches an answer to a question it may have asked several of.
    public static func reply(
        to request: CTCPMessage,
        version: String,
        userInfo: String,
        time: String
    ) -> CTCPMessage? {
        switch request.keyword {
        case "VERSION":
            return CTCPMessage(command: "VERSION", argument: version)
        case "PING":
            // Echoed verbatim, including the absence of an argument: the sender is
            // measuring a round trip against a token it chose, and a normalised answer
            // is one it cannot match.
            return CTCPMessage(command: "PING", argument: request.argument)
        case "TIME":
            return CTCPMessage(command: "TIME", argument: time)
        case "USERINFO":
            return CTCPMessage(command: "USERINFO", argument: userInfo)
        case "FINGER":
            // Traditionally the real name plus an idle time. The idle time is left off
            // rather than invented: this client does not track keystrokes, and a made-up
            // number is worse than a missing one.
            return CTCPMessage(command: "FINGER", argument: userInfo)
        case "CLIENTINFO":
            return CTCPMessage(
                command: "CLIENTINFO",
                argument: supported.joined(separator: " ")
            )
        default:
            // `ACTION` included. It is a line of conversation, and a client that answered
            // one would be answering every `/me` in every channel it sits in.
            return nil
        }
    }
}

/// The rate limit on CTCP replies: a token bucket over a monotonic clock.
///
/// **This is the whole defence against being used as an amplifier.** A CTCP request is
/// a line anyone can send, the reply is a line we send to an address they chose, and a
/// channel-wide `VERSION` multiplies one line by the size of the channel. Answering
/// without a limit turns this client into a reflector.
///
/// One bucket for the connection rather than one per sender. That is the conservative
/// direction — a flood from one nick does briefly silence replies to everyone else —
/// and it is the direction that cannot be defeated by spreading the flood over a
/// thousand spoofed sources, which per-sender buckets can.
public struct CTCPThrottle: Sendable {
    /// What happened to one request.
    public enum Outcome: Sendable, Equatable {
        /// Answer it.
        case allowed
        /// Do not. `firstOfBurst` is true exactly once per run of suppressions, so the
        /// user can be told the client is being flooded without being told fifty times.
        case suppressed(firstOfBurst: Bool)
    }

    /// How many replies may go out back to back before the limit bites.
    ///
    /// Five: enough that a person doing `/ctcp` a few times in a row never notices, and
    /// few enough that the acceptance run's fifty requests produce visibly fewer.
    public let burst: Int

    /// How long one token takes to come back.
    public let recovery: Duration

    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant
    private var isSuppressing = false

    public init(
        burst: Int = 5,
        recovery: Duration = .seconds(5),
        now: ContinuousClock.Instant
    ) {
        self.burst = burst
        self.recovery = recovery
        self.tokens = Double(burst)
        self.lastRefill = now
    }

    /// Spends a token if there is one.
    public mutating func admit(at now: ContinuousClock.Instant) -> Outcome {
        refill(to: now)
        guard tokens >= 1 else {
            defer { isSuppressing = true }
            return .suppressed(firstOfBurst: !isSuppressing)
        }
        tokens -= 1
        isSuppressing = false
        return .allowed
    }

    private mutating func refill(to now: ContinuousClock.Instant) {
        guard now > lastRefill else { return }
        let elapsed = lastRefill.duration(to: now).seconds
        let interval = recovery.seconds
        guard interval > 0 else {
            tokens = Double(burst)
            lastRefill = now
            return
        }
        tokens = min(Double(burst), tokens + elapsed / interval)
        lastRefill = now
    }
}
