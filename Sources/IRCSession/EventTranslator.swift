import IRCProtocol

/// Turns one inbound message into the events it means.
///
/// Pure, so the whole translation table is testable without a socket: given this line
/// and these capabilities, exactly these events in this order. Session-driven events —
/// ``IRCEvent/stateChanged(_:)``, ``IRCEvent/registered(_:)``,
/// ``IRCEvent/clientError(_:)`` — do not come from here, because they do not come from
/// a message.
public enum EventTranslator {
    /// CTCP's delimiter. Only `ACTION` is understood at this stage; every other CTCP
    /// request stays wrapped inside an ordinary message event, and is visible in `.raw`
    /// either way.
    static let ctcpDelimiter: Character = "\u{01}"

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
                mapping: mapping
            )
        }

        guard case .verb(let verb) = message.command else { return [] }

        switch verb.uppercased() {
        case "PRIVMSG", "NOTICE":
            guard let sender = message.source, parameters.count >= 2 else { return [] }
            let (text, isAction) = unwrapAction(parameters[1])
            return [
                .message(
                    target: Target(parameters[0], capabilities: capabilities),
                    sender: sender,
                    text: text,
                    kind: verb.uppercased() == "PRIVMSG" ? .privmsg : .notice,
                    isAction: isAction
                )
            ]

        case "JOIN":
            guard let who = message.source, let channel = parameters.first else { return [] }
            return [.joined(channel: IRCChannelName(channel, mapping: mapping), who: who)]

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
            guard let target = parameters.first else { return [] }
            return [
                .modeChanged(
                    target: Target(target, capabilities: capabilities),
                    who: message.source,
                    arguments: Array(parameters.dropFirst())
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
    private static func numericEvents(
        code: UInt16,
        parameters: [String],
        mapping: IRCCaseMapping
    ) -> [IRCEvent] {
        switch code {
        case 1:
            // The session emits `.registered` for this one, unconditionally.
            return []
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
        default:
            break
        }
        return [.numeric(code: code, parameters: parameters)]
    }

    /// Unwraps a CTCP `ACTION`, returning the text without its wrapper.
    ///
    /// `\u{01}ACTION waves\u{01}` is `* nick waves`. A malformed one — no closing
    /// delimiter, which happens when a message was truncated — is still recognized,
    /// because showing the action is better than showing the control characters.
    static func unwrapAction(_ text: String) -> (text: String, isAction: Bool) {
        let marker = "\(ctcpDelimiter)ACTION"
        guard text.hasPrefix(marker) else { return (text, false) }
        var body = text.dropFirst(marker.count)
        // The keyword has to end here, or a CTCP called `ACTIONS` would be mistaken for
        // one of ours and lose its first character.
        guard body.isEmpty || body.first == " " || body.first == ctcpDelimiter else {
            return (text, false)
        }
        if body.last == ctcpDelimiter { body = body.dropLast() }
        if body.first == " " { body = body.dropFirst() }
        return (String(body), true)
    }
}
