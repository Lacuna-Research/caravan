import IRCProtocol

/// Turns what the user typed into what should happen.
///
/// Pure, like ``EventTranslator`` and for the same reason: the whole command table is a
/// table, and a table is worth testing exhaustively rather than by hand against a socket.
/// Nothing here sends, connects or draws — it says what to do and the caller does it.
///
/// The one rule underneath all of it: **input never disappears without an answer.** Every
/// path either produces something for the wire or produces a ``CommandAction/error(_:)``
/// the user can read.
public struct CommandParser: Sendable {
    /// Decides what counts as a channel name, and folds targets. Refreshed per 005 by
    /// whoever owns the parser.
    public var capabilities: ServerCapabilities

    /// What `/ping` sends as its token, for the sender to match a reply against.
    ///
    /// Injected rather than generated: this type is pure and has no clock, and a `/ping`
    /// whose token changed under a test would be a test that could only assert its shape.
    /// The app passes a timestamp.
    public var pingToken: String

    public init(
        capabilities: ServerCapabilities = ServerCapabilities(),
        pingToken: String = "0"
    ) {
        self.capabilities = capabilities
        self.pingToken = pingToken
    }

    /// The actions for the contents of an input box, which may hold several lines.
    ///
    /// Several lines send as several messages, in order — the shape §7 settles on, where a
    /// multi-line paste fills the box and `Enter` is what sends it. Blank lines are
    /// skipped rather than sent as empty messages.
    public func actions(for input: String, activeTarget: Target?) -> [CommandAction] {
        input.split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { actions(forLine: String($0), activeTarget: activeTarget) }
    }

    /// One line's worth.
    func actions(forLine line: String, activeTarget: Target?) -> [CommandAction] {
        // Trailing whitespace only. **Leading spaces are never trimmed**: ASCII art is
        // part of what this client is for, and a leading run of spaces is load-bearing in
        // it. The consequence is that a line starting with a space is a message rather
        // than a command, which is the right way round.
        let text = line.trimmingTrailingWhitespace()
        guard !text.isEmpty else { return [] }

        // `//text` is how you say a message that begins with a slash. Checked before the
        // command prefix, or it would parse as a command called "/".
        if text.hasPrefix("//") {
            return message(String(text.dropFirst()), to: activeTarget, command: "message")
        }
        guard text.hasPrefix("/") else {
            return message(text, to: activeTarget, command: "message")
        }

        let (verb, rest) = split(String(text.dropFirst()))
        return command(verb, rest: rest, activeTarget: activeTarget)
    }

    // MARK: - The table

    /// Every verb the switch below answers to, for Tab completion to offer.
    ///
    /// **Here rather than in the UI**, because this switch is the one place that knows
    /// what a command is; a second list in the input box would be a second answer to the
    /// same question, and the one nobody edits is the one that goes stale. It is still a
    /// hand-kept list — Swift cannot enumerate a `switch` — so `everyKnownCommandParses`
    /// checks that nothing here falls through to the passthrough. That catches a name
    /// removed from the switch. A case *added* to the switch and not listed here can only
    /// be caught by reading, which is why they are adjacent.
    ///
    /// Aliases are included: someone who types `/j` wants to see it offered.
    public static let knownCommands = [
        "ame", "amsg", "away", "back", "ban", "clear", "clearall", "connect", "ctcp",
        "debug", "deop", "devoice", "disconnect", "invite", "j", "join", "kick", "kickban",
        "leave", "list", "m", "me", "mode", "msg", "names", "nick", "notice", "op", "oper",
        "part", "ping", "q", "query", "quit", "quote", "raw", "say", "server", "topic",
        "unban", "voice", "who", "whois", "whowas",
    ]

    private func command(_ verb: String, rest: String, activeTarget: Target?) -> [CommandAction] {
        // A bare `/`. It has to answer rather than vanish, and the answer people need is
        // that `//` is how you send a line that starts with one.
        guard !verb.isEmpty else {
            return [
                .error(
                    CommandError.usage("/<command> — or // to send a message starting with a slash")
                        .message
                )
            ]
        }

        switch verb.lowercased() {
        case "join", "j":
            return join(rest)

        case "part", "leave":
            return part(rest, activeTarget: activeTarget)

        case "msg", "m":
            return directed(rest, verb: "PRIVMSG", usage: "/msg <target> <message>")

        case "query", "q":
            return query(rest)

        case "notice":
            return directed(rest, verb: "NOTICE", usage: "/notice <target> <message>")

        case "me":
            return action(rest, to: activeTarget)

        case "nick":
            let (nick, _) = split(rest)
            guard !nick.isEmpty else {
                return [.error(CommandError.usage("/nick <nickname>").message)]
            }
            return [.send(IRCMessage(verb: "NICK", parameters: [nick]))]

        case "topic":
            return topic(rest, activeTarget: activeTarget)

        case "quit":
            return [.quit(reason: rest.isEmpty ? nil : rest)]

        case "disconnect":
            return [.disconnect]

        case "connect":
            return rest.isEmpty ? [.reconnect] : server(rest)

        case "server":
            guard !rest.isEmpty else {
                return [.error(CommandError.usage("/server <host> [[+]port] [password]").message)]
            }
            return server(rest)

        case "debug":
            return debug(rest)

        case "raw", "quote":
            guard let message = IRCMessage(line: rest) else {
                return [.error(CommandError.usage("/raw <IRC line>").message)]
            }
            return [.send(message)]

        // MARK: Asking the server about people and places

        case "whois", "whowas":
            // `/whois bob bob` asks bob's own server, which is how you get idle time — so
            // the arguments are passed through as typed rather than second-guessed.
            guard !rest.isEmpty else {
                return [.error(CommandError.usage("/\(verb.lowercased()) <nick>").message)]
            }
            return [.send(IRCMessage(verb: verb.uppercased(), parameters: words(rest)))]

        case "who":
            // A bare `/who` in a channel asks about that channel, which is the only thing
            // it could usefully mean.
            let mask = rest.isEmpty ? activeTarget?.raw : rest
            guard let mask else {
                return [.error(CommandError.noTargetInThisWindow(command: "/who").message)]
            }
            return [.send(IRCMessage(verb: "WHO", parameters: words(mask)))]

        case "names":
            guard let channel = channelOrActive(rest, activeTarget) else {
                return [.error(CommandError.noTargetInThisWindow(command: "/names").message)]
            }
            return [.send(IRCMessage(verb: "NAMES", parameters: [channel]))]

        case "list":
            // The channel *browser* is a later prompt; this sends LIST and lets the
            // numerics land in the status window like any other reply.
            return [.send(IRCMessage(verb: "LIST", parameters: words(rest)))]

        case "oper":
            let (name, password) = split(rest)
            guard !name.isEmpty, !password.isEmpty else {
                return [.error(CommandError.usage("/oper <name> <password>").message)]
            }
            // Redaction is `TraceBuffer`'s business, and it already strips `OPER`.
            return [.send(IRCMessage(verb: "OPER", parameters: [name, password]))]

        // MARK: Presence

        case "away":
            // `/away` with no reason is how you come back, per the RFC. `/back` is the
            // friendlier spelling of the same line.
            return [.send(IRCMessage(verb: "AWAY", parameters: rest.isEmpty ? [] : [rest]))]

        case "back":
            return [.send(IRCMessage(verb: "AWAY", parameters: []))]

        // MARK: Saying things

        case "say":
            // Exactly a plain line, but explicit — which is how you send text beginning
            // with a slash without doubling it.
            guard !rest.isEmpty else {
                return [.error(CommandError.usage("/say <message>").message)]
            }
            return message(rest, to: activeTarget, command: "/say")

        case "amsg", "ame":
            guard !rest.isEmpty else {
                return [.error(CommandError.usage("/\(verb.lowercased()) <message>").message)]
            }
            return [.toAllChannels(text: rest, isAction: verb.lowercased() == "ame")]

        case "ctcp":
            let (ctcpTarget, request) = split(rest)
            let (keyword, argument) = split(request)
            guard !ctcpTarget.isEmpty, !keyword.isEmpty else {
                return [.error(CommandError.usage("/ctcp <target> <request> [args]").message)]
            }
            // **A request is a PRIVMSG.** A `NOTICE` is a *reply*, and that split is the
            // only thing stopping two clients answering each other forever.
            let request2 = CTCPMessage(
                command: keyword.uppercased(),
                argument: argument.isEmpty ? nil : argument
            )
            return [
                .send(IRCMessage(verb: "PRIVMSG", parameters: [ctcpTarget, request2.wireForm]))
            ]

        case "ping":
            let (pingTarget, _) = split(rest)
            guard !pingTarget.isEmpty else {
                return [.error(CommandError.usage("/ping <nick>").message)]
            }
            // The argument is a token for the sender to match the reply against. A pure
            // parser has no clock, so the caller supplies one.
            let ping = CTCPMessage(command: "PING", argument: pingToken)
            return [.send(IRCMessage(verb: "PRIVMSG", parameters: [pingTarget, ping.wireForm]))]

        // MARK: The buffer itself

        case "clear":
            return [.clearScrollback(everywhere: false)]

        case "clearall":
            return [.clearScrollback(everywhere: true)]

        // MARK: Modes

        case "mode":
            return mode(rest, activeTarget: activeTarget)

        case "op", "deop", "voice", "devoice":
            return membership(verb.lowercased(), rest: rest, activeTarget: activeTarget)

        case "kick":
            return kick(rest, activeTarget: activeTarget)

        case "ban", "unban", "kickban":
            return ban(verb.lowercased(), rest: rest, activeTarget: activeTarget)

        case "invite":
            let (invitee, channelArgument) = split(rest)
            guard !invitee.isEmpty else {
                return [.error(CommandError.usage("/invite <nick> [#channel]").message)]
            }
            guard let channel = channelOrActive(channelArgument, activeTarget) else {
                return [.error(CommandError.noTargetInThisWindow(command: "/invite").message)]
            }
            return [.send(IRCMessage(verb: "INVITE", parameters: [invitee, channel]))]

        default:
            // mIRC's passthrough, and the reason this client is useful for anything not
            // yet wired up. Verbatim: a trailing parameter with spaces needs its own `:`,
            // exactly as it would typed into `/raw`.
            guard let message = IRCMessage(line: "\(verb.uppercased()) \(rest)") else {
                return []
            }
            return [.send(message)]
        }
    }

    // MARK: - Individual commands

    /// `/join #a,#b key1,key2`. A name with no channel prefix gets one, because typing
    /// `/join swift` is what people do and `JOIN swift` is only ever an error.
    private func join(_ rest: String) -> [CommandAction] {
        let (channels, keys) = split(rest)
        guard !channels.isEmpty else {
            return [
                .error(CommandError.usage("/join <#channel>[,<#channel>...] [key,...]").message)
            ]
        }
        let qualified =
            channels
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { qualifiedChannelName(String($0)) }
            .joined(separator: ",")
        let (keyList, _) = split(keys)
        let parameters = keyList.isEmpty ? [qualified] : [qualified, keyList]
        return [.send(IRCMessage(verb: "JOIN", parameters: parameters))]
    }

    /// `/part [#channel] [reason]`.
    ///
    /// **Parting is not closing.** This sends `PART` and stops; the buffer stays in the
    /// tree in its greyed not-joined state. Closing the buffer is the thing that parts —
    /// membership never outlives its buffer, but a buffer may outlive membership.
    private func part(_ rest: String, activeTarget: Target?) -> [CommandAction] {
        let (first, remainder) = split(rest)
        let channel: String
        let reason: String

        if !first.isEmpty, capabilities.isChannelName(first) {
            channel = first
            reason = remainder
        } else if case .channel(let active)? = activeTarget {
            channel = active.raw
            reason = rest
        } else {
            return [.error(CommandError.noTargetInThisWindow(command: "/part").message)]
        }

        let parameters = reason.isEmpty ? [channel] : [channel, reason]
        return [.send(IRCMessage(verb: "PART", parameters: parameters))]
    }

    /// `/msg`, `/query`, `/notice`: a target, then everything else as the text.
    private func directed(_ rest: String, verb: String, usage: String) -> [CommandAction] {
        let (target, text) = split(rest)
        guard !target.isEmpty, !text.isEmpty else {
            return [.error(CommandError.usage(usage).message)]
        }
        return [.send(IRCMessage(verb: verb, parameters: [target, text]))]
    }

    /// `/query <nick> [message]` — open the conversation window, optionally saying
    /// something in it.
    ///
    /// The message is optional, which is the whole difference from `/msg`: `/query bob`
    /// is "open a window for bob", and there is no other way to ask for one before he has
    /// said anything.
    ///
    /// A channel name is refused rather than quietly opened as a query. `/query #swift`
    /// is somebody reaching for `/join`, and a conversation window named after a channel
    /// would send `PRIVMSG #swift` from a window that looks like a private one.
    private func query(_ rest: String) -> [CommandAction] {
        let (nick, text) = split(rest)
        guard !nick.isEmpty else {
            return [.error(CommandError.usage("/query <nick> [message]").message)]
        }
        guard !capabilities.isChannelName(nick) else {
            return [.error(CommandError.notAPerson(command: "/query", target: nick).message)]
        }
        return [.openQuery(nick: nick, message: text.isEmpty ? nil : text)]
    }

    /// `/me waves` — a `PRIVMSG` wrapped in CTCP `ACTION`, to the window you are in.
    private func action(_ rest: String, to activeTarget: Target?) -> [CommandAction] {
        guard !rest.isEmpty else { return [.error(CommandError.usage("/me <action>").message)] }
        guard let activeTarget else {
            return [.error(CommandError.noTargetInThisWindow(command: "/me").message)]
        }
        let wrapped = CTCPMessage(command: "ACTION", argument: rest).wireForm
        return [.send(IRCMessage(verb: "PRIVMSG", parameters: [activeTarget.raw, wrapped]))]
    }

    /// `/topic [#channel] [text]`. With no text it asks rather than sets, which is the one
    /// way to read a topic without changing it.
    private func topic(_ rest: String, activeTarget: Target?) -> [CommandAction] {
        let (first, remainder) = split(rest)
        let channel: String
        let text: String?

        if !first.isEmpty, capabilities.isChannelName(first) {
            channel = first
            text = remainder.isEmpty ? nil : remainder
        } else if case .channel(let active)? = activeTarget {
            channel = active.raw
            text = rest.isEmpty ? nil : rest
        } else {
            return [.error(CommandError.noTargetInThisWindow(command: "/topic").message)]
        }

        let parameters = text.map { [channel, $0] } ?? [channel]
        return [.send(IRCMessage(verb: "TOPIC", parameters: parameters))]
    }

    /// `/server <host> [[+]port] [password]`.
    ///
    /// A `+` before the port means TLS, as it has in mIRC for twenty years. A bare port
    /// says nothing about TLS and leaves the setting alone rather than guessing from the
    /// number — guessing wrong in that direction sends a password in clear.
    private func server(_ rest: String) -> [CommandAction] {
        let (host, afterHost) = split(rest)
        let (portToken, password) = split(afterHost)

        var port: UInt16?
        var tls: Bool?
        if !portToken.isEmpty {
            var digits = Substring(portToken)
            if digits.first == "+" {
                tls = true
                digits = digits.dropFirst()
            }
            guard let value = UInt16(digits), value > 0 else {
                return [.error(CommandError.badPort(portToken).message)]
            }
            port = value
        }

        return [
            .connect(
                host: host,
                port: port,
                tls: tls,
                password: password.isEmpty ? nil : password
            )
        ]
    }

    /// `/debug [-i] [window | <file> | off]`, following mIRC.
    ///
    /// The destination is the **rest of the line**, not the next token: a path may contain
    /// spaces, and a client that silently truncated `~/Debug Logs/caravan.log` at the
    /// space would write to somewhere the user never named.
    ///
    /// `on` and `@anything` are accepted as `window` because that is what mIRC users type;
    /// `-i` on its own means the canvas, since it is the only destination that could be
    /// meant by a flag with nothing after it.
    private func debug(_ rest: String) -> [CommandAction] {
        var remainder = Substring(rest)
        var includesExistingTrace = false

        while remainder.hasPrefix("-") {
            let (flag, afterFlag) = split(String(remainder))
            for character in flag.dropFirst() where character != "i" {
                return [
                    .error(
                        CommandError.unknownFlag(command: "/debug", flag: "-\(character)").message
                    )
                ]
            }
            includesExistingTrace = true
            remainder = Substring(afterFlag)
        }

        let destination = String(remainder).trimmingCharacters(in: .whitespaces)
        switch destination.lowercased() {
        case "":
            return [
                .debug(includesExistingTrace ? .toCanvas(includingExistingTrace: true) : .report)
            ]
        case "off":
            return [.debug(.off)]
        case "window", "on":
            return [.debug(.toCanvas(includingExistingTrace: includesExistingTrace))]
        default:
            if destination.hasPrefix("@") {
                return [.debug(.toCanvas(includingExistingTrace: includesExistingTrace))]
            }
            return [
                .debug(
                    .toFile(path: destination, includingExistingTrace: includesExistingTrace)
                )
            ]
        }
    }

    /// Plain text, to the window's target.
    private func message(_ text: String, to activeTarget: Target?, command: String)
        -> [CommandAction]
    {
        guard let activeTarget else {
            return [.error(CommandError.noTargetInThisWindow(command: command).message)]
        }
        return [.send(IRCMessage(verb: "PRIVMSG", parameters: [activeTarget.raw, text]))]
    }

    // MARK: - Modes

    /// `/mode [#channel|nick] [modes] [args]`.
    ///
    /// With no mode string it *asks* — `MODE #swift` returns the channel's modes in a 324,
    /// which is the only way to read them without changing them.
    private func mode(_ rest: String, activeTarget: Target?) -> [CommandAction] {
        let (first, remainder) = split(rest)
        // A first token that names a channel or is a nick with modes after it is the
        // target; anything starting with `+` or `-` is a mode string for this window.
        let looksLikeModes = first.hasPrefix("+") || first.hasPrefix("-")
        let target: String
        let arguments: String
        if !first.isEmpty && !looksLikeModes {
            target = first
            arguments = remainder
        } else if let active = activeTarget?.raw {
            target = active
            arguments = rest
        } else {
            return [.error(CommandError.noTargetInThisWindow(command: "/mode").message)]
        }
        let parameters = arguments.isEmpty ? [target] : [target] + words(arguments)
        return [.send(IRCMessage(verb: "MODE", parameters: parameters))]
    }

    /// `/op`, `/deop`, `/voice`, `/devoice` — **several people at once**.
    ///
    /// `/op a b c` is one `MODE #swift +ooo a b c`, split across as many lines as
    /// `ISUPPORT MODES=` allows. Sending one line per nick would work and would be three
    /// times the traffic and three times the flood risk, which is what `MODES=` exists to
    /// bound.
    private func membership(_ verb: String, rest: String, activeTarget: Target?)
        -> [CommandAction]
    {
        let letter: Character = verb.hasSuffix("voice") ? "v" : "o"
        let isSet = !verb.hasPrefix("de")

        var tokens = words(rest)
        // An explicit channel may lead, for opping someone from another window.
        let channel: String
        if let first = tokens.first, capabilities.isChannelName(first) {
            channel = first
            tokens.removeFirst()
        } else if case .channel(let active)? = activeTarget {
            channel = active.raw
        } else {
            return [.error(CommandError.noTargetInThisWindow(command: "/\(verb)").message)]
        }
        guard !tokens.isEmpty else {
            return [.error(CommandError.usage("/\(verb) [#channel] <nick> [nick...]").message)]
        }
        return modeLines(channel: channel, letter: letter, isSet: isSet, arguments: tokens)
    }

    /// Splits mode changes into as many `MODE` lines as the server will take.
    private func modeLines(
        channel: String,
        letter: Character,
        isSet: Bool,
        arguments: [String]
    ) -> [CommandAction] {
        // `MODES` is optional in `ISUPPORT`; three is the RFC-era convention every server
        // accepts, and is what to assume when the server does not say.
        let perLine = max(1, capabilities.maximumModesPerCommand ?? 3)
        return stride(from: 0, to: arguments.count, by: perLine).map { start in
            let batch = Array(arguments[start..<min(start + perLine, arguments.count)])
            let modeString =
                String(isSet ? "+" : "-") + String(repeating: letter, count: batch.count)
            return .send(IRCMessage(verb: "MODE", parameters: [channel, modeString] + batch))
        }
    }

    /// `/kick [#channel] <nick> [reason]`.
    private func kick(_ rest: String, activeTarget: Target?) -> [CommandAction] {
        var tokens = words(rest)
        let channel: String
        if let first = tokens.first, capabilities.isChannelName(first) {
            channel = first
            tokens.removeFirst()
        } else if case .channel(let active)? = activeTarget {
            channel = active.raw
        } else {
            return [.error(CommandError.noTargetInThisWindow(command: "/kick").message)]
        }
        guard let nick = tokens.first else {
            return [.error(CommandError.usage("/kick [#channel] <nick> [reason]").message)]
        }
        // The reason keeps its internal spacing, which `words` would have thrown away.
        let reason = remainder(of: rest, after: nick)
        let parameters = reason.isEmpty ? [channel, nick] : [channel, nick, reason]
        return [.send(IRCMessage(verb: "KICK", parameters: parameters))]
    }

    /// `/ban`, `/unban`, `/kickban`.
    ///
    /// The mask is **not** decided here: `*!*@host` needs the channel roster, which is the
    /// connection's and not something a pure parser should grow. See
    /// ``CommandAction/ban(channel:subject:isSet:kickReason:)``.
    private func ban(_ verb: String, rest: String, activeTarget: Target?) -> [CommandAction] {
        var tokens = words(rest)
        let channel: String
        if let first = tokens.first, capabilities.isChannelName(first) {
            channel = first
            tokens.removeFirst()
        } else if case .channel(let active)? = activeTarget {
            channel = active.raw
        } else {
            return [.error(CommandError.noTargetInThisWindow(command: "/\(verb)").message)]
        }
        guard let subject = tokens.first else {
            return [.error(CommandError.usage("/\(verb) [#channel] <nick|mask>").message)]
        }
        let isKickban = verb == "kickban"
        let reason = isKickban ? remainder(of: rest, after: subject) : ""
        return [
            .ban(
                channel: channel,
                subject: subject,
                isSet: verb != "unban",
                kickReason: isKickban ? (reason.isEmpty ? "" : reason) : nil
            )
        ]
    }

    /// The channel a command should act on: an explicit one, or the window's.
    private func channelOrActive(_ argument: String, _ activeTarget: Target?) -> String? {
        let (first, _) = split(argument)
        if !first.isEmpty, capabilities.isChannelName(first) { return first }
        if case .channel(let active)? = activeTarget { return active.raw }
        return first.isEmpty ? nil : first
    }

    // MARK: - Helpers

    /// Splits off the first whitespace-delimited token, returning it and the untouched
    /// remainder. The remainder keeps its internal spacing, which is what makes a message
    /// body survive the parse.
    private func split(_ text: String) -> (first: String, rest: String) {
        let trimmed = Substring(text).drop { $0 == " " || $0 == "\t" }
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (String(trimmed), "")
        }
        let rest = trimmed[trimmed.index(after: space)...].drop { $0 == " " || $0 == "\t" }
        return (String(trimmed[trimmed.startIndex..<space]), String(rest))
    }

    /// Whitespace-separated tokens, with empties dropped.
    private func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Everything after the first occurrence of `token`, with its internal spacing intact.
    ///
    /// `words` is fine for arguments and wrong for a reason: `/kick bob go  away` must
    /// keep the double space, because it is a sentence a person wrote.
    private func remainder(of text: String, after token: String) -> String {
        guard let range = text.range(of: token) else { return "" }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Adds a channel prefix to a bare name.
    private func qualifiedChannelName(_ name: String) -> String {
        guard !capabilities.isChannelName(name) else { return name }
        let prefix =
            capabilities.channelTypes.contains("#") ? "#" : capabilities.channelTypes.sorted().first
        return prefix.map { "\($0)\(name)" } ?? name
    }
}

extension String {
    /// Trims trailing spaces and tabs, and any stray carriage return.
    ///
    /// A trailing `\r` arrives with text copied from a Windows source, and a trailing
    /// space arrives from almost everywhere. Neither should reach the wire.
    fileprivate func trimmingTrailingWhitespace() -> String {
        var text = Substring(self)
        while let last = text.last, last == " " || last == "\t" || last == "\r" {
            text = text.dropLast()
        }
        return String(text)
    }
}
