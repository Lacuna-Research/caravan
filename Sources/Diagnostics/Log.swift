import Foundation
import OSLog

/// Namespaced loggers, one per subsystem area.
///
/// Diagnostic logging only: what the client was doing, never what was said. Message
/// payloads belong in ``TraceBuffer``, which is bounded, redacted on insert, and only
/// leaves the process when the user exports it. The unified log is none of those
/// things — it persists to disk outside our control and any admin process can read it.
public enum Log {
    /// Falls back to a literal when there is no bundle identifier, which is the case
    /// under `swift test`.
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.lacuna-research.irc-client"

    /// Connection lifecycle, TLS, framing.
    public static let transport = Logger(subsystem: subsystem, category: "transport")

    /// Parsing and serialization failures. Backticked because `protocol` is a keyword;
    /// the category string itself is plain "protocol".
    public static let `protocol` = Logger(subsystem: subsystem, category: "protocol")

    /// Registration, capability negotiation, connection state machine.
    public static let session = Logger(subsystem: subsystem, category: "session")

    /// Window and view-model behaviour.
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
