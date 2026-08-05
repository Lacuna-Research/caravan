/// Where one connection attempt has got to.
///
/// A single ``IRCConnection`` walks this once and stops: `.idle` on creation, then
/// `.connecting`, then either `.ready` or a terminal `.failed`/`.cancelled`. Nothing
/// follows a terminal state, which is what lets the state stream finish.
public enum TransportState: Sendable, Equatable {
    case idle
    case connecting
    case ready

    /// The connection ended for a reason nobody asked for.
    case failed(TransportError)

    /// ``IRCConnection/disconnect()`` was called. Deliberate, not a network problem —
    /// prompt 5's reconnect logic turns on exactly this distinction, so it is a separate
    /// case rather than a flag on `.failed`.
    case cancelled
}

/// Everything this layer can fail with.
///
/// Concrete rather than `any Error` so the state stream is `Sendable` and `Equatable`,
/// and so `IRCSession` can match on a failure without importing Network. `NWError`
/// detail survives as the reason string, which is what a diagnostic needs.
public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPort(UInt16)
    case connectionFailed(reason: String)
    case receiveFailed(reason: String)
    case sendFailed(reason: String)

    /// The peer closed the stream. Distinct from `.cancelled`: the server hanging up
    /// after `ERROR` is not the same event as the user choosing to leave.
    case closedByPeer

    public var description: String {
        switch self {
        case .invalidPort(let port): "invalid port \(port)"
        case .connectionFailed(let reason): "connection failed: \(reason)"
        case .receiveFailed(let reason): "receive failed: \(reason)"
        case .sendFailed(let reason): "send failed: \(reason)"
        case .closedByPeer: "connection closed by peer"
        }
    }
}

/// Whether and how to wrap the connection in TLS.
public enum TLSMode: Sendable, Equatable {
    case disabled

    /// - Parameter allowSelfSigned: When true, a certificate the system will not
    ///   validate is accepted and recorded in ``IRCConnection/acceptedCertificate``
    ///   instead of failing the handshake.
    case enabled(allowSelfSigned: Bool)
}

/// What the peer presented, recorded so the caller can show it rather than having to
/// take our word that the connection is secure.
public struct TLSCertificate: Sendable, Equatable {
    /// Subject summary, when the certificate has one.
    public let subject: String?

    /// SHA-256 of the DER encoding, lowercase hex, colon-separated. The form a user can
    /// compare against a fingerprint published elsewhere.
    public let sha256Fingerprint: String

    /// Whether the system trust evaluation passed. False means it was accepted only
    /// because the caller asked for `allowSelfSigned`.
    public let systemTrusted: Bool

    public init(subject: String?, sha256Fingerprint: String, systemTrusted: Bool) {
        self.subject = subject
        self.sha256Fingerprint = sha256Fingerprint
        self.systemTrusted = systemTrusted
    }
}
