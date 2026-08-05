import IRCProtocol

/// Whether a message was a `PRIVMSG` or a `NOTICE`.
///
/// They render differently and, by convention, a client never auto-replies to a notice.
public enum MessageKind: Sendable, Hashable {
    case privmsg
    case notice
}

/// Everything the session tells the rest of the app.
///
/// The single seam above ``IRCSession``: the UI, the logger and later the scripting
/// engine all consume this and nothing else. Adding a case is how the client learns to
/// understand something new; nothing above needs to parse a wire line again.
///
/// **Every inbound message emits ``raw(_:)``, recognized or not, and it comes first.**
/// A server can say nothing that the client cannot show, which is what makes the status
/// window trustworthy — and when something goes wrong, the raw line is the evidence.
public enum IRCEvent: Sendable, Equatable {
    /// One inbound message, exactly as it arrived.
    case raw(IRCMessage)

    case stateChanged(SessionState)

    /// Registration completed. Fires on 001, carrying what was known then.
    ///
    /// 002–004 arrive *after* it and refine ``IRCSession/serverInfo``; they surface here
    /// as ``numeric(code:parameters:)``, which is also how a client displays them. There
    /// is no line marking the end of that burst, so waiting for one would mean guessing.
    case registered(ServerInfo)

    case message(
        target: Target,
        sender: IRCSource,
        text: String,
        kind: MessageKind,
        isAction: Bool
    )

    case joined(channel: IRCChannelName, who: IRCSource)
    case parted(channel: IRCChannelName, who: IRCSource, reason: String?)
    case quit(who: IRCSource, reason: String?)
    case nickChanged(who: IRCSource, newNick: String)
    case kicked(channel: IRCChannelName, by: IRCSource, nick: String, reason: String?)
    case topicChanged(channel: IRCChannelName, who: IRCSource?, topic: String)

    /// A `MODE` line, with its arguments unparsed.
    ///
    /// Interpreting them needs `CHANMODES` to know which take a parameter, and the
    /// channel state to apply them to. That is prompt 8's; this reports the change
    /// happened and what was said.
    case modeChanged(target: Target, who: IRCSource?, arguments: [String])

    /// One 353 batch. `NAMES` arrives in several, each ending with 366.
    case namesReply(channel: IRCChannelName, names: [String])
    case endOfNames(channel: IRCChannelName)

    /// Any numeric not already represented by a more specific event.
    ///
    /// The exceptions are 001, 353 and 366, whose whole content is carried by
    /// ``registered(_:)``, ``namesReply(channel:names:)`` and
    /// ``endOfNames(channel:)``. Everything else — including the MOTD, 002–005, and
    /// every error numeric — arrives here, so a status window that renders `.numeric`
    /// shows the server's own words without needing a case per code.
    case numeric(code: UInt16, parameters: [String])

    /// Our own diagnostic, addressed to the user rather than to the server.
    case clientError(String)
}
