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
    case enabled(TLSTrust)
}

/// Which certificates to believe.
public enum TLSTrust: Sendable, Equatable {
    /// Stock system validation. A certificate that fails it fails the connection, and
    /// nothing is asked of the user.
    case system

    /// System validation, and where that fails, ask — SSH's model.
    ///
    /// Replaces the `allowSelfSigned` flag this used to be. That flag accepted an
    /// unvalidated certificate silently, on the promise that a UI would eventually ask;
    /// a promise nothing enforced. Trust here is a *decision*, and with no evaluator
    /// supplied to make it the handshake fails closed rather than open.
    case trustOnFirstUse
}

/// The parts of a TLS setup that are objects rather than values.
///
/// Kept out of ``TLSMode`` so that stays `Equatable` and cheap to compare, and so a
/// `SessionConfiguration` remains a description of *what* to connect to rather than a
/// bundle of callbacks.
public struct TLSCredentials: Sendable {
    /// Consulted when system validation fails under ``TLSTrust/trustOnFirstUse``.
    ///
    /// Called with the certificate and the hostname asked for. `nil` means nobody can be
    /// asked, and an unvalidated certificate is then refused.
    public var trustEvaluator: (@Sendable (TLSCertificate, String) async -> Bool)?

    /// The client certificate to present, which is the whole of CertFP: SASL `EXTERNAL`
    /// says "I am whoever this certificate's fingerprint is registered to".
    public var clientIdentity: TLSClientIdentity?

    public init(
        trustEvaluator: (@Sendable (TLSCertificate, String) async -> Bool)? = nil,
        clientIdentity: TLSClientIdentity? = nil
    ) {
        self.trustEvaluator = trustEvaluator
        self.clientIdentity = clientIdentity
    }
}

/// What the peer presented, recorded so the caller can show it rather than having to
/// take our word that the connection is secure.
public struct TLSCertificate: Sendable, Equatable {
    /// Subject summary, when the certificate has one.
    public let subject: String?

    /// SHA-256 of the DER encoding, lowercase hex, colon-separated. The form a user can
    /// compare against a fingerprint published elsewhere.
    public let sha256Fingerprint: String

    /// Whether the system trust evaluation passed. False means the connection continued
    /// only because something answered the trust question.
    public let systemTrusted: Bool

    public init(subject: String?, sha256Fingerprint: String, systemTrusted: Bool) {
        self.subject = subject
        self.sha256Fingerprint = sha256Fingerprint
        self.systemTrusted = systemTrusted
    }
}
