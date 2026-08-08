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

    /// `/query <nick> [message]`: open a conversation window, and say something in it if
    /// there was anything to say.
    ///
    /// Not a `send`, because the window is the point: `/query bob` with no message is a
    /// complete command, and it puts nothing on the wire at all.
    case openQuery(nick: String, message: String?)

    /// `/amsg` and `/ame`: say this in **every channel on every connected network**.
    ///
    /// Not a run of `send`s, because the parser is pure and cannot know what those
    /// channels are — that is the app's knowledge, and this is the parser saying what was
    /// asked for rather than guessing at it.
    case toAllChannels(text: String, isAction: Bool)

    /// `/ban`, `/unban` and `/kickban`: **ban this person**, mask to be decided.
    ///
    /// A ban wants `*!*@host`, and the host lives in the channel roster — which the parser
    /// does not have and should not grow. So the action names the person and the
    /// connection, which does have the roster, resolves the mask. A subject that already
    /// looks like a mask is passed through untouched.
    ///
    /// `kickReason` non-`nil` makes it `/kickban`: the kick follows the ban, in that
    /// order, so the ban is in place before they can rejoin.
    case ban(channel: String, subject: String, isSet: Bool, kickReason: String?)

    /// `/clear` and `/clearall`: empty this buffer's scrollback, or every one.
    ///
    /// Scrollback belongs to the view models, not to the session, so this cannot be a
    /// `send` and cannot be done by the parser.
    case clearScrollback(everywhere: Bool)

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

    /// `/ignore`: stop listening to somebody, start again, or say who is on the list.
    ///
    /// Nothing goes on the wire — an ignore is entirely the client's, which is why it is an
    /// action rather than a `send`. The parser resolves the flags because they are a pure
    /// letter table; it does *not* resolve a bare nick into a mask, since
    /// `IgnoreList.mask(for:)` is where that convention lives and the parser has no business
    /// holding a second copy of it.
    ///
    /// `subject` is `nil` for a bare `/ignore`, which lists them.
    case ignore(subject: String?, levels: IgnoreLevel, duration: Int?, isRemoval: Bool)

    /// `/debug`: point the wire trace somewhere, or stop.
    ///
    /// The answer the user reads back is the *controller's*, not the parser's — it names
    /// the file that was actually opened, which is knowledge no pure function has.
    case debug(DebugCommand)
}

/// Where the wire trace should go, following mIRC's `/debug`.
///
/// The trace itself is always running — ``Diagnostics/TraceBuffer`` is on from launch —
/// so this is only ever about *destinations*. That is what makes
/// ``toCanvas(includingExistingTrace:)`` with the flag set useful: you turn debugging on
/// after something has already gone wrong, and the ring still has it.
public enum DebugCommand: Sendable, Equatable {
    /// `/debug window` — stream to the Debug & Settings canvas.
    case toCanvas(includingExistingTrace: Bool)

    /// `/debug <file>` — append to a file. The file is redacted, because everything in
    /// the trace was redacted on insert; there is no unredacted path to write.
    case toFile(path: String, includingExistingTrace: Bool)

    /// `/debug off` — stop every destination.
    case off

    /// Bare `/debug` — say where the trace is currently going.
    case report
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
    /// A flag the command does not have.
    case unknownFlag(command: String, flag: String)
    /// A command that wants a person was given a channel.
    case notAPerson(command: String, target: String)
    /// A mode command was given a mode letter the server never declared.
    case unknownMode(command: String, mode: Character)

    public var message: String {
        switch self {
        case .noTargetInThisWindow(let command):
            "\(command) needs a target here — this window is not a channel or a query"
        case .usage(let usage):
            "Usage: \(usage)"
        case .badPort(let port):
            "\(port) is not a valid port"
        case .unknownFlag(let command, let flag):
            "\(command) has no \(flag) flag"
        case .notAPerson(let command, let target):
            "\(command) opens a conversation with a person — \(target) is a channel, so use /join"
        case .unknownMode(let command, let mode):
            "\(command): this server does not have a +\(mode) channel mode"
        }
    }
}
