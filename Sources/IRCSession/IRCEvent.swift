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
    /// A topic, whether someone just set it (`who` is them) or the server reported the
    /// standing one on join (332, `who` is `nil`).
    ///
    /// An empty topic means the channel has none — which is what 331 says, and what a
    /// `TOPIC` clearing one sends.
    case topicChanged(channel: IRCChannelName, who: IRCSource?, topic: String)

    /// 333: who set the standing topic and when, in Unix epoch seconds. Follows the 332
    /// for the same channel, and some servers never send it.
    case topicAuthor(channel: IRCChannelName, nick: String, setAt: Int?)

    /// A `MODE` line, split into individual changes.
    ///
    /// Splitting needs `CHANMODES` and `PREFIX` to know which modes take an argument,
    /// which is why it happens here rather than in every consumer. ``ModeChange`` says
    /// what could not be accounted for; the whole line is in ``raw(_:)`` regardless.
    case modeChanged(target: Target, who: IRCSource?, changes: [ModeChange])

    /// 324: the channel's current modes, in reply to a `MODE` query or on join.
    case channelModes(channel: IRCChannelName, changes: [ModeChange])

    /// A join that the server refused, with the reason in a form worth acting on.
    case joinFailed(channel: IRCChannelName, reason: JoinFailure, text: String)

    /// One 353 batch. `NAMES` arrives in several, each ending with 366.
    case namesReply(channel: IRCChannelName, names: [String])
    case endOfNames(channel: IRCChannelName)

    /// Any numeric not already represented by a more specific event.
    ///
    /// The exceptions are the numerics whose whole content another case already
    /// carries: 001, 331/332/333, 324, 353, 366 and the join failures 471–477.
    /// Everything else — including the MOTD, 002–005, and
    /// every error numeric — arrives here, so a status window that renders `.numeric`
    /// shows the server's own words without needing a case per code.
    case numeric(code: UInt16, parameters: [String])

    /// A channel's state after something changed it, as an immutable snapshot.
    ///
    /// Fires *after* the event that caused it, so a consumer renders the join line and
    /// then updates its nick list. One event carrying the whole channel, rather than a
    /// case per kind of change, is what keeps the transition logic in one place instead of
    /// duplicated into every view that draws a member list.
    case channelChanged(Channel)

    /// A channel buffer was closed, which is the one thing that removes it. Parting or
    /// being kicked does not: membership never outlives its buffer, but a buffer may
    /// outlive membership.
    case channelClosed(IRCChannelName)

    /// Our own diagnostic, addressed to the user rather than to the server.
    case clientError(String)
}

/// Why a `JOIN` was refused.
///
/// Typed rather than left as a numeric because these are the errors a user is expected to
/// *do* something about — supply a key, get invited, wait for a slot — and a client that
/// only echoes "475" has not helped.
public enum JoinFailure: Sendable, Hashable {
    /// 471. The channel is at its user limit.
    case channelIsFull
    /// 473. Invite only.
    case inviteOnly
    /// 474. We are banned.
    case banned
    /// 475. Wrong or missing channel key.
    case badKey
    /// 476. The channel mask is malformed.
    case badChannelMask
    /// 477. The channel requires a registered nickname.
    case needsRegisteredNick

    /// The numeric that carries it, or `nil` for a code that is not a join failure.
    public init?(numeric code: UInt16) {
        switch code {
        case 471: self = .channelIsFull
        case 473: self = .inviteOnly
        case 474: self = .banned
        case 475: self = .badKey
        case 476: self = .badChannelMask
        case 477: self = .needsRegisteredNick
        default: return nil
        }
    }

    /// A short phrase for a line the user reads. The server's own text is carried
    /// alongside in ``IRCEvent/joinFailed(channel:reason:text:)`` and is usually better;
    /// this is what to say when it is empty.
    public var summary: String {
        switch self {
        case .channelIsFull: "the channel is full"
        case .inviteOnly: "the channel is invite only"
        case .banned: "you are banned"
        case .badKey: "the channel key is wrong or missing"
        case .badChannelMask: "the channel name is not valid"
        case .needsRegisteredNick: "the channel requires a registered nickname"
        }
    }
}
