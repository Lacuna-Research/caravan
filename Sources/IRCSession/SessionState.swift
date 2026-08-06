import IRCTransport

/// What the server told us about itself during registration.
///
/// `ISUPPORT` is deliberately *not* here: 005 arrives after 001, so folding it in would
/// mean either re-announcing `.connected` for every 005 line or publishing a half-filled
/// struct. It lives on ``IRCSession/capabilities`` instead, which is a value that keeps
/// being refined rather than an event.
public struct ServerInfo: Sendable, Equatable {
    /// The nick registration actually settled on, which may not be the configured one.
    public var nick: String

    /// Text of 001, the welcome line.
    public var welcome: String?

    /// Text of 002, which names the host and version as prose.
    public var hostInfo: String?

    /// Server name, from 004 or the source of 001.
    public var serverName: String?
    /// Server version, from 004 or 002.
    public var version: String?
    /// Text of 003, when the server was created.
    public var created: String?
    /// User mode letters this server knows, from 004.
    public var userModes: String?
    /// Channel mode letters this server knows, from 004.
    public var channelModes: String?

    public init(nick: String) {
        self.nick = nick
    }
}

/// Why the session is not connected.
public enum DisconnectReason: Sendable, Equatable {
    /// Never connected in the first place.
    case notStarted
    /// ``IRCSession/disconnect()`` was called.
    case userInitiated
    /// The server sent `ERROR`, with its reason.
    case serverError(String)
    /// The transport failed.
    case transportFailed(TransportError)
    /// Registration could not complete.
    case registrationFailed(String)

    /// The server's TLS certificate was not trusted — refused by the user, or presented
    /// where there was nobody to ask.
    ///
    /// Never reconnected from, for the same reason as ``authenticationFailed(_:)``: it is
    /// an answer, and asking again is not how you get a different one.
    case trustRefused

    /// Authentication was refused, or could not be completed.
    ///
    /// Its own case, and never reconnected from: a wrong password does not become right on
    /// the second attempt, and a client that keeps trying one is how an account gets
    /// locked out and an IP gets throttled.
    case authenticationFailed(String)
    /// Nothing arrived and our own `PING` went unanswered.
    case timedOut
    /// Neither the TCP connection nor registration finished in time.
    ///
    /// Its own case rather than a `timedOut`: telling the two apart is the difference
    /// between "the server never started talking to us" and "the server stopped".
    case connectTimedOut
}

/// Where the session is in its lifecycle.
public enum SessionState: Sendable, Equatable {
    case disconnected(reason: DisconnectReason)
    /// TCP (and TLS) are being established.
    case connecting
    /// Connected; `NICK`/`USER` sent, waiting for 001.
    case registering
    case connected(ServerInfo)
    /// Waiting out the backoff before attempt `attempt`.
    case reconnecting(attempt: Int, nextAttemptIn: Duration)

    /// Whether an attempt is in flight or established. A reconnect must never be
    /// scheduled while this holds.
    public var isActive: Bool {
        switch self {
        case .connecting, .registering, .connected: true
        case .disconnected, .reconnecting: false
        }
    }
}
