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

    public init(capabilities: ServerCapabilities = ServerCapabilities()) {
        self.capabilities = capabilities
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

        case "query":
            // Stage 1 has no query buffers, so this is `/msg` with a usage line instead
            // of a window. Listed rather than dropped, or the passthrough below would
            // send the server a command called QUERY.
            return directed(rest, verb: "PRIVMSG", usage: "/query <nick> <message>")

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

        case "raw", "quote":
            guard let message = IRCMessage(line: rest) else {
                return [.error(CommandError.usage("/raw <IRC line>").message)]
            }
            return [.send(message)]

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

    /// `/me waves` — a `PRIVMSG` wrapped in CTCP `ACTION`, to the window you are in.
    private func action(_ rest: String, to activeTarget: Target?) -> [CommandAction] {
        guard !rest.isEmpty else { return [.error(CommandError.usage("/me <action>").message)] }
        guard let activeTarget else {
            return [.error(CommandError.noTargetInThisWindow(command: "/me").message)]
        }
        let wrapped =
            "\(EventTranslator.ctcpDelimiter)ACTION \(rest)\(EventTranslator.ctcpDelimiter)"
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

    /// Plain text, to the window's target.
    private func message(_ text: String, to activeTarget: Target?, command: String)
        -> [CommandAction]
    {
        guard let activeTarget else {
            return [.error(CommandError.noTargetInThisWindow(command: command).message)]
        }
        return [.send(IRCMessage(verb: "PRIVMSG", parameters: [activeTarget.raw, text]))]
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
