import IRCProtocol

/// Turns one inbound message into the events it means.
///
/// Pure, so the whole translation table is testable without a socket: given this line
/// and these capabilities, exactly these events in this order. Session-driven events —
/// ``IRCEvent/stateChanged(_:)``, ``IRCEvent/registered(_:)``,
/// ``IRCEvent/clientError(_:)`` — do not come from here, because they do not come from
/// a message.
public enum EventTranslator {
    /// The events for one inbound message, `.raw` first.
    public static func events(
        for message: IRCMessage,
        capabilities: ServerCapabilities
    ) -> [IRCEvent] {
        var events: [IRCEvent] = [.raw(message)]
        events.append(contentsOf: specificEvents(for: message, capabilities: capabilities))
        return events
    }

    private static func specificEvents(
        for message: IRCMessage,
        capabilities: ServerCapabilities
    ) -> [IRCEvent] {
        let mapping = capabilities.caseMapping
        let parameters = message.parameters

        if let code = message.command.numericCode {
            return numericEvents(
                code: code,
                parameters: parameters,
                capabilities: capabilities
            )
        }

        guard case .verb(let verb) = message.command else { return [] }

        switch verb.uppercased() {
        case "PRIVMSG", "NOTICE":
            guard let sender = message.source, parameters.count >= 2 else { return [] }
            let isRequest = verb.uppercased() == "PRIVMSG"
            let target = Target(parameters[0], capabilities: capabilities)

            // A CTCP is an ordinary message whose text is wrapped in `\u{01}`. `ACTION`
            // is the exception in both directions: it is unwrapped into the message it
            // is, and it is never treated as a request.
            if let ctcp = CTCPMessage(text: parameters[1]), !ctcp.isAction {
                return [
                    isRequest
                        ? .ctcpRequest(
                            target: target,
                            sender: sender,
                            request: ctcp,
                            tags: message.tags
                        )
                        : .ctcpReply(
                            target: target,
                            sender: sender,
                            reply: ctcp,
                            tags: message.tags
                        )
                ]
            }

            let (text, isAction) = unwrapAction(parameters[1])
            return [
                .message(
                    target: target,
                    sender: sender,
                    text: text,
                    kind: isRequest ? .privmsg : .notice,
                    isAction: isAction,
                    tags: message.tags
                )
            ]

        case "JOIN":
            guard let who = message.source, let channel = parameters.first else { return [] }
            // `extended-join` widens the line to `JOIN <channel> <account> :<realname>`,
            // where `*` is the server's way of saying "logged in to nothing".
            let account = parameters.count > 1 ? nilIfUnset(parameters[1]) : nil
            let realName = parameters.count > 2 ? nilIfEmpty(parameters[2]) : nil
            return [
                .joined(
                    channel: IRCChannelName(channel, mapping: mapping),
                    who: who,
                    account: account,
                    realName: realName
                )
            ]

        case "AWAY":
            // `away-notify`. A reason means away; no parameter at all means back.
            guard let who = message.source else { return [] }
            return [.awayChanged(who: who, message: parameters.first.flatMap(nilIfEmpty))]

        case "ACCOUNT":
            guard let who = message.source, let account = parameters.first else { return [] }
            return [.accountChanged(who: who, account: nilIfUnset(account))]

        case "CHGHOST":
            guard let who = message.source, parameters.count >= 2 else { return [] }
            return [.hostChanged(who: who, user: parameters[0], host: parameters[1])]

        case "SETNAME":
            guard let who = message.source, let realName = parameters.first else { return [] }
            return [.realNameChanged(who: who, realName: realName)]

        case "INVITE":
            guard parameters.count >= 2 else { return [] }
            return [
                .invited(
                    by: message.source,
                    nick: parameters[0],
                    channel: IRCChannelName(parameters[1], mapping: mapping)
                )
            ]

        case "FAIL", "WARN", "NOTE":
            guard let severity = StandardReply.Severity(rawValue: verb.uppercased()),
                let reply = StandardReply(message: parameters, severity: severity)
            else { return [] }
            return [.standardReply(reply)]

        case "BATCH":
            // `BATCH +<ref> <type> [params]` opens one, `BATCH -<ref>` closes it.
            guard let reference = parameters.first, reference.count > 1 else { return [] }
            let identifier = String(reference.dropFirst())
            guard reference.hasPrefix("+") else { return [.batchEnded(reference: identifier)] }
            return [
                .batchStarted(
                    reference: identifier,
                    type: parameters.count > 1 ? parameters[1] : "",
                    parameters: Array(parameters.dropFirst(2))
                )
            ]

        case "CAP", "AUTHENTICATE", "BOUNCER":
            // Negotiation and the bouncer's own protocol, which the session drives and
            // reports as `.capabilitiesChanged`, `.authenticated` and `.bouncerNetworks`.
            // Visible as `.raw` either way, which is where someone debugging a failed
            // handshake goes looking.
            return []

        case "PART":
            guard let who = message.source, let channel = parameters.first else { return [] }
            return [
                .parted(
                    channel: IRCChannelName(channel, mapping: mapping),
                    who: who,
                    reason: parameters.count > 1 ? parameters[1] : nil
                )
            ]

        case "QUIT":
            guard let who = message.source else { return [] }
            return [.quit(who: who, reason: parameters.first)]

        case "NICK":
            guard let who = message.source, let newNick = parameters.first else { return [] }
            return [.nickChanged(who: who, newNick: newNick)]

        case "KICK":
            guard let by = message.source, parameters.count >= 2 else { return [] }
            return [
                .kicked(
                    channel: IRCChannelName(parameters[0], mapping: mapping),
                    by: by,
                    nick: parameters[1],
                    reason: parameters.count > 2 ? parameters[2] : nil
                )
            ]

        case "TOPIC":
            guard parameters.count >= 2 else { return [] }
            return [
                .topicChanged(
                    channel: IRCChannelName(parameters[0], mapping: mapping),
                    who: message.source,
                    topic: parameters[1]
                )
            ]

        case "MODE":
            guard let first = parameters.first else { return [] }
            let target = Target(first, capabilities: capabilities)
            return [
                .modeChanged(
                    target: target,
                    who: message.source,
                    changes: ModeParser.changes(
                        in: Array(parameters.dropFirst()),
                        isChannel: target.isChannel,
                        capabilities: capabilities
                    )
                )
            ]

        default:
            // Unrecognized, and therefore visible only as `.raw`. That is the point of
            // the raw guarantee: a command this client has never heard of still reaches
            // the status window.
            return []
        }
    }

    /// A numeric becomes its specific event where there is one, and
    /// ``IRCEvent/numeric(code:parameters:)`` otherwise.
    ///
    /// Suppression is conditional on a specific event actually being produced, not on the
    /// code alone: a 353 too short to name a channel falls through to `.numeric` and is
    /// still shown, rather than vanishing because its code is on a list.
    /// The nicks in a 730/731 trailing parameter, without their user@host.
    ///
    /// Servers differ: some send `bob`, some `bob!u@h`, and some send several separated by
    /// commas with spaces after them. All three are one list of nicks.
    static func monitorTargets(_ parameters: [String]) -> [String] {
        guard let list = parameters.last else { return [] }
        return
            list
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.split(separator: "!").first.map(String.init) ?? String($0) }
            .filter { !$0.isEmpty }
    }

    private static func numericEvents(
        code: UInt16,
        parameters: [String],
        capabilities: ServerCapabilities
    ) -> [IRCEvent] {
        let mapping = capabilities.caseMapping
        switch code {
        case 1:
            // The session emits `.registered` for this one, unconditionally.
            return []
        // MARK: Presence

        case 730, 731:
            // `<client> :nick[!user@host][,nick...]`. The trailing parameter is a list, and
            // the user@host part is optional and not wanted here — the notify list is keyed
            // on nicks, and the host of somebody who just signed on is not news.
            let online = code == 730
            return monitorTargets(parameters).map {
                .presenceChanged(nick: $0, isOnline: online)
            }

        case 303:
            // `RPL_ISON`: `<client> :nick nick nick`, and it names *only* who is online.
            // Diffing it against what was asked for is the session's job, because the
            // question is not in the answer.
            let online = parameters.last.map { $0.split(separator: " ").map(String.init) } ?? []
            return [.notifyBaseline(online: online, offline: [])]

        case 734:
            // `ERR_MONLISTFULL`: `<client> <limit> <targets> :Monitor list is full`. The
            // user has to see this — the names past the limit are indistinguishable from
            // offline, which is the one way this feature can lie.
            let limit = parameters.count > 1 ? parameters[1] : "?"
            let refused = parameters.count > 2 ? parameters[2] : ""
            return [
                .clientError(
                    "This server monitors at most \(limit) names, so it refused: \(refused)"
                )
            ]

        case 305:
            return [.awayStateChanged(isAway: false)]

        case 306:
            return [.awayStateChanged(isAway: true)]

        case 331:
            // `<client> <channel> :No topic is set`. An empty topic *is* the answer, and
            // saying so keeps one representation of "no topic" rather than two.
            if parameters.count >= 2 {
                return [
                    .topicChanged(
                        channel: IRCChannelName(parameters[1], mapping: mapping),
                        who: nil,
                        topic: ""
                    )
                ]
            }
        case 332:
            // `<client> <channel> :<topic>`
            if parameters.count >= 3 {
                return [
                    .topicChanged(
                        channel: IRCChannelName(parameters[1], mapping: mapping),
                        who: nil,
                        topic: parameters[2]
                    )
                ]
            }
        case 333:
            // `<client> <channel> <nick> <setat>`. The timestamp is occasionally a
            // full source rather than a bare nick, and occasionally missing entirely.
            if parameters.count >= 3 {
                return [
                    .topicAuthor(
                        channel: IRCChannelName(parameters[1], mapping: mapping),
                        nick: IRCSource(prefix: parameters[2]).nick ?? parameters[2],
                        setAt: parameters.count > 3 ? Int(parameters[3]) : nil
                    )
                ]
            }
        case 324:
            // `<client> <channel> <modestring> [<arguments>...]`
            if parameters.count >= 3 {
                return [
                    .channelModes(
                        channel: IRCChannelName(parameters[1], mapping: mapping),
                        changes: ModeParser.changes(
                            in: Array(parameters.dropFirst(2)),
                            isChannel: true,
                            capabilities: capabilities
                        )
                    )
                ]
            }
        case 367, 346, 348, 728:
            // `<client> <channel> <mask> [<setter> <timestamp>]`, and 728 inserts the mode
            // letter before the mask because it was invented later and by someone else.
            //
            // The setter and timestamp are optional in practice: several servers send the
            // mask alone, and a client that required all five would show nothing at all
            // rather than the one field that matters.
            let hasModeColumn = code == 728
            let base = hasModeColumn ? 3 : 2
            if parameters.count > base {
                let letter =
                    (hasModeColumn ? parameters[2].first : nil)
                    ?? Self.listMode(numeric: code)
                return [
                    .listModeEntry(
                        channel: IRCChannelName(parameters[1], mapping: mapping),
                        mode: letter,
                        mask: parameters[base],
                        setBy: parameters.count > base + 1
                            ? IRCSource(prefix: parameters[base + 1]).nick ?? parameters[base + 1]
                            : nil,
                        setAt: parameters.count > base + 2 ? Int(parameters[base + 2]) : nil
                    )
                ]
            }
        case 368, 347, 349, 729:
            if parameters.count >= 2 {
                let letter =
                    (code == 729 && parameters.count > 2 ? parameters[2].first : nil)
                    ?? Self.listMode(numeric: code)
                return [
                    .listModeEnd(
                        channel: IRCChannelName(parameters[1], mapping: mapping),
                        mode: letter
                    )
                ]
            }
        case 471, 473, 474, 475, 476, 477:
            // `<client> <channel> :<reason>`
            if parameters.count >= 2, let reason = JoinFailure(numeric: code) {
                return [
                    .joinFailed(
                        channel: IRCChannelName(parameters[1], mapping: mapping),
                        reason: reason,
                        text: parameters.count > 2 ? parameters[2] : reason.summary
                    )
                ]
            }
        case 353:
            // `<client> <symbol> <channel> :<names>`
            if parameters.count >= 4 {
                return [
                    .namesReply(
                        channel: IRCChannelName(parameters[2], mapping: mapping),
                        names: parameters[3].split(separator: " ").map(String.init)
                    )
                ]
            }
        case 366:
            // `<client> <channel> :End of /NAMES list`
            if parameters.count >= 2 {
                return [.endOfNames(channel: IRCChannelName(parameters[1], mapping: mapping))]
            }
        case 341:
            // `<client> <nick> <channel>` — our own `/invite` was accepted.
            if parameters.count >= 3 {
                return [
                    .invited(
                        by: nil,
                        nick: parameters[1],
                        channel: IRCChannelName(parameters[2], mapping: mapping)
                    )
                ]
            }
        case 900:
            // `<client> <nick!user@host> <account> :You are now logged in as ...`
            if parameters.count >= 3 {
                return [.authenticated(account: parameters[2])]
            }
        default:
            break
        }
        return [.numeric(code: code, parameters: parameters)]
    }

    /// Which mode letter a list numeric is about.
    ///
    /// `q` for 728/729 is the fallback rather than the rule — those carry the letter
    /// explicitly, because "quiet" is not in any RFC and networks disagree about it.
    static func listMode(numeric code: UInt16) -> Character {
        switch code {
        case 367, 368: "b"
        case 346, 347: "I"
        case 348, 349: "e"
        default: "q"
        }
    }

    /// `*` is the wire's "none" for an account name, and is not a nick anyone can hold.
    private static func nilIfUnset(_ value: String) -> String? {
        value == "*" || value.isEmpty ? nil : value
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    /// Unwraps a CTCP `ACTION`, returning the text without its wrapper.
    ///
    /// `\u{01}ACTION waves\u{01}` is `* nick waves`. A malformed one — no closing
    /// delimiter, which happens when a message was truncated — is still recognized,
    /// because showing the action is better than showing the control characters.
    ///
    /// Anything that is not an `ACTION` comes back unchanged and not-an-action, including
    /// another CTCP: the caller above has already split those off into
    /// ``IRCEvent/ctcpRequest(target:sender:request:tags:)``, and the local-echo path
    /// uses this to render `/me` without needing to know the difference.
    public static func unwrapAction(_ text: String) -> (text: String, isAction: Bool) {
        guard let ctcp = CTCPMessage(text: text), ctcp.isAction else { return (text, false) }
        return (ctcp.argument ?? "", true)
    }
}
