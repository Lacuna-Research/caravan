import IRCProtocol

/// What one line of input asked for.
///
/// The parser is pure and knows nothing about windows, sockets or SwiftUI, so it says
/// what should happen rather than doing it. Most input produces exactly one action; a
/// few produce two, and a multi-line box produces a run of them.
public enum CommandAction: Sendable, Equatable {
    /// Put this on the wire.
    case send(IRCMessage)

    /// Tell the user something went wrong, in the window they typed in.
    ///
    /// Argument errors are a *line*, not a dialog and not silence — the rule being that
    /// input never disappears without an answer.
    case error(String)

    /// `/server`, and `/connect` with an argument: point the client at a host.
    ///
    /// Identity — nick, ident, real name — is deliberately absent: it belongs to the
    /// client's settings, and a command that silently changed it would be a surprise.
    case connect(host: String, port: UInt16?, tls: Bool?, password: String?)

    /// `/connect` with no argument: reconnect where we already were.
    case reconnect

    /// `/disconnect`: drop the connection without asking the server first.
    case disconnect

    /// `/quit`: say goodbye, *then* drop the connection.
    ///
    /// One action rather than a `send` plus a `disconnect`, because the order matters and
    /// a caller that got it backwards would send `QUIT` into a closed socket.
    case quit(reason: String?)
}

/// Why a command could not be carried out, phrased for the person who typed it.
///
/// Separate from the message so the wording lives in one place and the tests can assert
/// on the case rather than on prose.
public enum CommandError: Sendable, Equatable {
    /// The command needs a target and the window has none — a status window, typically.
    case noTargetInThisWindow(command: String)
    /// Not enough arguments. Carries the usage line to print.
    case usage(String)
    /// A `/server` port that is not a number, or not a port.
    case badPort(String)

    public var message: String {
        switch self {
        case .noTargetInThisWindow(let command):
            "\(command) needs a target here — this window is not a channel or a query"
        case .usage(let usage):
            "Usage: \(usage)"
        case .badPort(let port):
            "\(port) is not a valid port"
        }
    }
}
