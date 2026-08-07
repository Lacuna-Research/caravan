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

    /// One `PRIVMSG` or `NOTICE`.
    ///
    /// `tags` is the message's own tag section, carried because two capabilities put
    /// something there that only the consumer can use: `server-time`'s `time` says when
    /// the line was *said* rather than when it arrived, and `msgid` is what prompt 12 will
    /// de-duplicate a replayed log against. Carried whole rather than picked apart here —
    /// this module has no clock and no date formatter, and inventing one to parse a
    /// timestamp it does not itself use would be the wrong layer.
    case message(
        target: Target,
        sender: IRCSource,
        text: String,
        kind: MessageKind,
        isAction: Bool,
        tags: IRCTags
    )

    /// A CTCP request — a `PRIVMSG` whose text is wrapped in `\u{01}`.
    ///
    /// Separate from ``message(target:sender:text:kind:isAction:tags:)`` because it is not
    /// something anybody said: a `VERSION` request is a question addressed to the
    /// *client*, and rendering it as a line of conversation is how it used to appear in
    /// a channel window as control characters. `ACTION` is deliberately not here — it is
    /// a message wearing a CTCP's wrapper, and arrives as one.
    ///
    /// The session answers what it knows how to answer, subject to ``CTCPThrottle``.
    /// Emitting the request regardless is what makes a flood visible rather than silent.
    case ctcpRequest(target: Target, sender: IRCSource, request: CTCPMessage, tags: IRCTags)

    /// A CTCP reply — a `NOTICE` whose text is wrapped in `\u{01}`, answering a request
    /// we sent.
    ///
    /// **Never answered, by anyone.** The request/reply split between `PRIVMSG` and
    /// `NOTICE` is the only thing standing between two clients and an infinite exchange,
    /// and this case existing separately is what makes that rule mechanical.
    case ctcpReply(target: Target, sender: IRCSource, reply: CTCPMessage, tags: IRCTags)

    /// A `JOIN`. `account` and `realName` are populated only under `extended-join`, and
    /// `account` is `nil` for someone who is not logged in — the wire's `*`.
    case joined(
        channel: IRCChannelName,
        who: IRCSource,
        account: String?,
        realName: String?
    )
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

    /// One entry of a channel's ban, quiet, invite or except list.
    ///
    /// **One case for four lists, because they are one numeric shape four times.** 367,
    /// 346, 348 and the de-facto 728 differ only in which mode letter they are about, and
    /// a client with four near-identical events would grow four near-identical dialogs.
    case listModeEntry(
        channel: IRCChannelName,
        mode: Character,
        mask: String,
        setBy: String?,
        setAt: Int?
    )

    /// The end of one such list — 368, 347, 349, 729.
    case listModeEnd(channel: IRCChannelName, mode: Character)

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

    /// Something the client wants to say that is not a failure.
    ///
    /// Separate from ``clientError(_:)`` because the red reserved for failures is worth
    /// keeping: "this server has no SASL, identifying to NickServ instead" is the client
    /// doing its job, not the client failing at it.
    case clientNotice(String)

    // MARK: - IRCv3

    /// Capability negotiation settled, or moved: also fires for `CAP NEW` and `CAP DEL`,
    /// which is the whole point of `cap-notify`.
    case capabilitiesChanged(NegotiatedCapabilities)

    /// We are logged in to services, from 900 or from a successful SASL exchange.
    case authenticated(account: String)

    /// A `FAIL`, `WARN` or `NOTE` under `standard-replies`.
    case standardReply(StandardReply)

    /// Someone became away or came back, under `away-notify`. `message` is `nil` for a
    /// return, and an away reason otherwise.
    case awayChanged(who: IRCSource, message: String?)

    /// Someone logged in to or out of services, under `account-notify`. `account` is `nil`
    /// for a logout — the wire's `*`.
    case accountChanged(who: IRCSource, account: String?)

    /// Someone's user@host changed without a reconnect, under `chghost`.
    case hostChanged(who: IRCSource, user: String, host: String)

    /// Someone changed their real name, under `setname`.
    case realNameChanged(who: IRCSource, realName: String)

    /// An invitation, whether ours (341) or someone else's seen under `invite-notify`.
    case invited(by: IRCSource?, nick: String, channel: IRCChannelName)

    /// A `BATCH` opening or closing.
    ///
    /// Carried rather than acted on: nothing needs to group lines until prompt 4 replays
    /// `chathistory` into a buffer. Surfacing them means the reference is already in the
    /// event stream when it does, rather than only in `.raw`.
    case batchStarted(reference: String, type: String, parameters: [String])
    case batchEnded(reference: String)

    // MARK: - The bouncer

    /// The upstream networks a bouncer is holding, as they now stand.
    ///
    /// The whole list rather than a delta, even when the change was one network: the
    /// consumer opens and closes buffers from this, and reconciling a list is a great deal
    /// easier to get right than applying a stream of edits to one. Fires on the reply to
    /// `BOUNCER LISTNETWORKS` and again on every `BOUNCER NETWORK` under
    /// `soju.im/bouncer-networks-notify`.
    case bouncerNetworks([BouncerNetwork])
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
