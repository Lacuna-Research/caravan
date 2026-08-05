import IRCProtocol
import Testing

@testable import IRCSession

/// Given this input and this window, exactly these actions.
///
/// The parser is pure, so the whole command table runs without a socket and there is no
/// reason not to be exhaustive. Expectations are written as the wire lines that would go
/// out, which is the form a bug in this layer actually shows up as.
@Suite("Command parsing")
struct CommandParserTests {
    private static let parser: CommandParser = {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: ["CASEMAPPING=ascii", "CHANTYPES=#&", "PREFIX=(ov)@+"])
        return CommandParser(capabilities: capabilities)
    }()

    private static let channel = Target(
        "#swift",
        capabilities: {
            var capabilities = ServerCapabilities()
            capabilities.apply(tokens: ["CASEMAPPING=ascii", "CHANTYPES=#&"])
            return capabilities
        }()
    )

    /// The lines an input would put on the wire. Anything that is not a send fails the
    /// test loudly rather than being skipped.
    ///
    /// Note the colons, or their absence: `wireForm` marks a trailing parameter only when
    /// it has to — when it is empty, holds a space, or starts with a colon. `PRIVMSG
    /// #swift hello` and `PRIVMSG #swift :hello` are the same message, and the former is
    /// what actually goes out.
    private func wire(_ input: String, in target: Target? = channel) -> [String] {
        Self.parser.actions(for: input, activeTarget: target).map { action in
            guard case .send(let message) = action else { return "NOT A SEND: \(action)" }
            return message.wireForm
        }
    }

    private func actions(_ input: String, in target: Target? = channel) -> [CommandAction] {
        Self.parser.actions(for: input, activeTarget: target)
    }

    /// The text of the single error an input produces.
    private func error(_ input: String, in target: Target? = channel) throws -> String {
        let actions = Self.parser.actions(for: input, activeTarget: target)
        #expect(actions.count == 1, "expected exactly one error, got \(actions)")
        guard case .error(let message)? = actions.first else {
            throw ExpectedAnError(actions: actions)
        }
        return message
    }

    private struct ExpectedAnError: Error { let actions: [CommandAction] }

    private static let channelTarget = channel

    // MARK: - Plain text

    @Test("plain text goes to the window's target")
    func plainText() {
        #expect(wire("hello there") == ["PRIVMSG #swift :hello there"])
    }

    /// A status window has no target, so there is nowhere for a message to go — and
    /// saying so is the requirement. Silence would be the bug.
    @Test("plain text with no target is an error, not silence")
    func plainTextWithoutTarget() throws {
        #expect(try error("hello", in: nil).contains("not a channel"))
    }

    @Test("// sends a message that starts with a slash")
    func doubledSlash() {
        #expect(wire("//slashed") == ["PRIVMSG #swift /slashed"])
        #expect(wire("///three") == ["PRIVMSG #swift //three"])
    }

    /// ASCII art is part of what this client is for, and a leading run of spaces is
    /// load-bearing in it.
    @Test("leading whitespace is preserved; trailing whitespace is not")
    func whitespace() {
        #expect(wire("   ___/") == ["PRIVMSG #swift :   ___/"])
        #expect(wire("hello   ") == ["PRIVMSG #swift hello"])
        // A stray carriage return arrives with anything copied from a Windows source.
        #expect(wire("hello\r") == ["PRIVMSG #swift hello"])
    }

    @Test("an empty line produces nothing at all")
    func emptyInput() {
        #expect(actions("").isEmpty)
        #expect(actions("   ").isEmpty)
        #expect(actions("\n\n").isEmpty)
    }

    /// §7's shape: a multi-line box sends its lines as separate messages, in order.
    @Test("several lines send as several messages, in order")
    func multipleLines() {
        #expect(
            wire("first\nsecond") == [
                "PRIVMSG #swift first", "PRIVMSG #swift second",
            ]
        )
        // A blank line in the middle of a paste is not an empty message.
        #expect(
            wire("first\n\nsecond") == [
                "PRIVMSG #swift first", "PRIVMSG #swift second",
            ]
        )
        #expect(
            wire("/join #other\nhello") == [
                "JOIN #other", "PRIVMSG #swift hello",
            ]
        )
    }

    // MARK: - /join

    @Test("join takes a list and an optional key list")
    func join() {
        #expect(wire("/join #a") == ["JOIN #a"])
        #expect(wire("/j #a") == ["JOIN #a"])
        #expect(wire("/join #a,#b") == ["JOIN #a,#b"])
        #expect(wire("/join #a,#b k1,k2") == ["JOIN #a,#b k1,k2"])
        #expect(wire("/join &local") == ["JOIN &local"])
    }

    /// `/join swift` is what people type, and `JOIN swift` is only ever an error.
    @Test("a bare channel name gets a prefix")
    func joinAddsPrefix() {
        #expect(wire("/join swift") == ["JOIN #swift"])
        #expect(wire("/join swift,vapor") == ["JOIN #swift,#vapor"])
        #expect(wire("/join swift,#vapor") == ["JOIN #swift,#vapor"])
    }

    @Test("join with no argument prints usage")
    func joinUsage() throws {
        #expect(try error("/join").contains("/join"))
    }

    // MARK: - /part

    /// **Parting is not closing.** This sends `PART` and stops — the buffer stays in the
    /// tree, greyed. Closing a buffer is what parts; the two are deliberately asymmetric.
    @Test("part defaults to the current channel and never closes the buffer")
    func part() {
        #expect(wire("/part") == ["PART #swift"])
        #expect(wire("/part so long") == ["PART #swift :so long"])
        #expect(wire("/part #other") == ["PART #other"])
        #expect(wire("/part #other so long") == ["PART #other :so long"])
        #expect(actions("/part").allSatisfy { if case .send = $0 { true } else { false } })
    }

    @Test("part with no channel and no current channel is an error")
    func partWithoutTarget() throws {
        #expect(try error("/part", in: nil).contains("/part"))
    }

    // MARK: - /msg, /query, /notice

    @Test("directed commands take a target and the rest as text")
    func directed() {
        #expect(wire("/msg bob hello there") == ["PRIVMSG bob :hello there"])
        #expect(wire("/m bob hi") == ["PRIVMSG bob hi"])
        #expect(wire("/notice #swift heads up") == ["NOTICE #swift :heads up"])
        #expect(wire("/msg #other cross-window") == ["PRIVMSG #other cross-window"])
    }

    @Test("a directed command missing its text prints usage")
    func directedUsage() throws {
        #expect(try error("/msg").contains("/msg"))
        #expect(try error("/msg bob").contains("/msg"))
        #expect(try error("/notice bob").contains("/notice"))
    }

    /// Stage 1 has no query buffers, so `/query` is `/msg`. Listed rather than dropped, or
    /// the unknown-command passthrough would send the server a command called `QUERY`.
    @Test("query behaves as msg and never reaches the server as QUERY")
    func query() throws {
        #expect(wire("/query bob hi") == ["PRIVMSG bob hi"])
        let usage = try error("/query bob")
        #expect(usage.contains("/query"))
        #expect(!usage.contains("QUERY"))
    }

    // MARK: - /me

    @Test("me wraps the text in a CTCP ACTION addressed to the window")
    func action() {
        let delimiter = "\u{01}"
        #expect(wire("/me waves") == ["PRIVMSG #swift :\(delimiter)ACTION waves\(delimiter)"])
    }

    @Test("me needs both a target and something to do")
    func actionErrors() throws {
        #expect(try error("/me").contains("/me"))
        #expect(try error("/me waves", in: nil).contains("/me"))
    }

    // MARK: - /nick and /topic

    @Test("nick takes exactly one argument")
    func nick() throws {
        #expect(wire("/nick bob") == ["NICK bob"])
        // Trailing junk is dropped rather than sent as a second parameter.
        #expect(wire("/nick bob and more") == ["NICK bob"])
        #expect(try error("/nick").contains("/nick"))
    }

    /// With no text it asks rather than sets, which is the only way to read a topic
    /// without changing it.
    @Test("topic queries with no text and sets with it")
    func topic() throws {
        #expect(wire("/topic") == ["TOPIC #swift"])
        #expect(wire("/topic a new topic") == ["TOPIC #swift :a new topic"])
        #expect(wire("/topic #other") == ["TOPIC #other"])
        #expect(wire("/topic #other a new topic") == ["TOPIC #other :a new topic"])
        #expect(try error("/topic", in: nil).contains("/topic"))
    }

    // MARK: - Connection commands

    @Test("quit carries its reason and disconnect does not ask the server")
    func quitAndDisconnect() {
        #expect(actions("/quit") == [.quit(reason: nil)])
        #expect(actions("/quit so long") == [.quit(reason: "so long")])
        #expect(actions("/disconnect") == [.disconnect])
    }

    @Test("connect with no argument reconnects where we were")
    func reconnect() {
        #expect(actions("/connect") == [.reconnect])
    }

    /// A `+` before the port means TLS, as it has in mIRC for twenty years. A bare port
    /// says nothing about it: guessing wrong in that direction sends a password in clear.
    @Test("server takes a host, an optional port and an optional password")
    func server() {
        #expect(
            actions("/server irc.example.org")
                == [.connect(host: "irc.example.org", port: nil, tls: nil, password: nil)]
        )
        #expect(
            actions("/server irc.example.org +6697")
                == [.connect(host: "irc.example.org", port: 6697, tls: true, password: nil)]
        )
        #expect(
            actions("/server irc.example.org 6667")
                == [.connect(host: "irc.example.org", port: 6667, tls: nil, password: nil)]
        )
        #expect(
            actions("/server irc.example.org 6667 hunter2")
                == [.connect(host: "irc.example.org", port: 6667, tls: nil, password: "hunter2")]
        )
        #expect(
            actions("/connect irc.example.org +6697")
                == [.connect(host: "irc.example.org", port: 6697, tls: true, password: nil)]
        )
    }

    @Test("a server with no host or a bad port says so")
    func serverErrors() throws {
        #expect(try error("/server").contains("/server"))
        #expect(try error("/server irc.example.org nope").contains("nope"))
        #expect(try error("/server irc.example.org 0").contains("0"))
        #expect(try error("/server irc.example.org 99999").contains("99999"))
    }

    // MARK: - Passthrough

    @Test("raw and quote send a line verbatim")
    func raw() throws {
        #expect(wire("/raw PING :token") == ["PING token"])
        #expect(wire("/quote MODE #a +o bob") == ["MODE #a +o bob"])
        #expect(try error("/raw").contains("/raw"))
    }

    /// mIRC's passthrough, and what makes the client immediately useful for anything not
    /// yet wired up.
    @Test("an unknown command is uppercased and sent verbatim")
    func unknownCommand() {
        #expect(wire("/whois bob") == ["WHOIS bob"])
        #expect(wire("/WhoIs bob") == ["WHOIS bob"])
        #expect(wire("/away") == ["AWAY"])
        #expect(wire("/oper alice hunter2") == ["OPER alice hunter2"])
        // The colon is the user's to add, exactly as it would be in `/raw`.
        #expect(wire("/away :back later") == ["AWAY :back later"])
    }

    /// A bare slash has to answer rather than vanish, and the answer people need is what
    /// `//` is for.
    @Test("a bare slash explains itself")
    func bareSlash() throws {
        #expect(try error("/").contains("//"))
    }

    // MARK: - Casemapping

    /// The parser classifies channel names with the server's `CHANTYPES`, not a hardcoded
    /// `#`, so a server declaring only `#` does not treat `&local` as a nickname.
    @Test("channel classification comes from CHANTYPES")
    func channelTypes() {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: ["CHANTYPES=#"])
        let parser = CommandParser(capabilities: capabilities)
        let actions = parser.actions(for: "/part &local bye", activeTarget: Self.channelTarget)
        guard case .send(let message)? = actions.first else {
            Issue.record("expected a send, got \(actions)")
            return
        }
        // `&local` is not a channel on this server, so it reads as the start of the
        // reason for parting the window we are in.
        #expect(message.wireForm == "PART #swift :&local bye")
    }
}
