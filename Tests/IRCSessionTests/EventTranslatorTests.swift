import IRCProtocol
import Testing

@testable import IRCSession

/// Given this raw line, exactly these events, in this order.
///
/// The translator is pure, so the whole table runs without a socket and there is no
/// reason not to be exhaustive about it.
@Suite("Event translation")
struct EventTranslatorTests {
    /// A server declaring `#` channels, ASCII casemapping and `@+` status prefixes.
    private static let capabilities: ServerCapabilities = {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: ["CASEMAPPING=ascii", "CHANTYPES=#&", "STATUSMSG=@+"])
        return capabilities
    }()

    private func events(_ line: String) throws -> [IRCEvent] {
        let message = try #require(IRCMessage(line: line), "line should parse: \(line)")
        return EventTranslator.events(for: message, capabilities: Self.capabilities)
    }

    private func channel(_ name: String) -> IRCChannelName {
        IRCChannelName(name, mapping: .ascii)
    }

    private func user(_ nick: String) -> IRCSource {
        .user(nick: nick, user: "u", host: "h")
    }

    // MARK: - The raw guarantee

    /// The load-bearing rule: nothing a server says can become invisible.
    @Test(
        "every message yields .raw first, whatever it is",
        arguments: [
            "PING :12345",
            ":irc.example.org 001 alice :Welcome",
            ":alice!u@h PRIVMSG #swift :hello",
            "SOMETHINGNOBODYHASEVERSENT with args",
            ":irc.example.org 999 alice :a numeric from the future",
            "ERROR :Closing link",
        ]
    )
    func rawAlwaysComesFirst(line: String) throws {
        let events = try events(line)
        let message = try #require(IRCMessage(line: line))
        #expect(events.first == .raw(message))
    }

    @Test("an unrecognized command yields .raw and nothing else")
    func unrecognizedCommandIsRawOnly() throws {
        let line = ":irc.example.org FROBNICATE #swift :who knows"
        #expect(try events(line).count == 1)
        #expect(try events(line) == [.raw(#require(IRCMessage(line: line)))])
    }

    /// PING is answered by the session, and is still visible to everything above it.
    @Test("a message the session handles itself is still reported")
    func handledMessagesAreStillVisible() throws {
        #expect(try events("PING :12345").count == 1)
        #expect(try events("ERROR :Closing link").count == 1)
    }

    // MARK: - Messages

    @Test("PRIVMSG to a channel")
    func channelMessage() throws {
        #expect(
            try events(":bob!u@h PRIVMSG #swift :hello there").dropFirst() == [
                .message(
                    target: .channel(channel("#swift")),
                    sender: user("bob"),
                    text: "hello there",
                    kind: .privmsg,
                    isAction: false
                )
            ]
        )
    }

    @Test("PRIVMSG to us is a nick target, not a channel")
    func privateMessage() throws {
        #expect(
            try events(":bob!u@h PRIVMSG alice :psst").dropFirst() == [
                .message(
                    target: .nick(IRCNick("alice", mapping: .ascii)),
                    sender: user("bob"),
                    text: "psst",
                    kind: .privmsg,
                    isAction: false
                )
            ]
        )
    }

    @Test("NOTICE is distinguished from PRIVMSG")
    func notice() throws {
        guard
            case .message(_, _, _, let kind, _) = try #require(
                try events(":bob!u@h NOTICE #swift :heads up").last
            )
        else {
            Issue.record("expected a message event")
            return
        }
        #expect(kind == .notice)
    }

    @Test("a CTCP ACTION is unwrapped and flagged")
    func action() throws {
        #expect(
            try events(":bob!u@h PRIVMSG #swift :\u{01}ACTION waves\u{01}").dropFirst() == [
                .message(
                    target: .channel(channel("#swift")),
                    sender: user("bob"),
                    text: "waves",
                    kind: .privmsg,
                    isAction: true
                )
            ]
        )
    }

    @Test(
        "action unwrapping handles the awkward spellings",
        arguments: [
            ("\u{01}ACTION waves\u{01}", "waves", true),
            ("\u{01}ACTION waves", "waves", true),  // Truncated: still an action.
            ("\u{01}ACTION\u{01}", "", true),
            ("\u{01}ACTION", "", true),
            ("\u{01}VERSION\u{01}", "\u{01}VERSION\u{01}", false),
            ("\u{01}ACTIONS are cool\u{01}", "\u{01}ACTIONS are cool\u{01}", false),
            ("ACTION without the delimiter", "ACTION without the delimiter", false),
            ("a normal message", "a normal message", false),
        ]
    )
    func actionSpellings(input: String, text: String, isAction: Bool) {
        let result = EventTranslator.unwrapAction(input)
        #expect(result.text == text)
        #expect(result.isAction == isAction)
    }

    /// `@#swift` addresses the channel's operators. It is still the channel's window.
    @Test("a STATUSMSG prefix does not turn a channel into a nick")
    func statusMessagePrefix() throws {
        guard
            case .message(let target, _, _, _, _) = try #require(
                try events(":bob!u@h PRIVMSG @#swift :ops only").last
            )
        else {
            Issue.record("expected a message event")
            return
        }
        #expect(target == .channel(channel("#swift")))
        #expect(target.isChannel)
    }

    // MARK: - Membership

    @Test("JOIN")
    func join() throws {
        #expect(
            try events(":bob!u@h JOIN #swift").dropFirst() == [
                .joined(channel: channel("#swift"), who: user("bob"))
            ]
        )
    }

    @Test("PART, with and without a reason")
    func part() throws {
        #expect(
            try events(":bob!u@h PART #swift :bye").dropFirst() == [
                .parted(channel: channel("#swift"), who: user("bob"), reason: "bye")
            ]
        )
        #expect(
            try events(":bob!u@h PART #swift").dropFirst() == [
                .parted(channel: channel("#swift"), who: user("bob"), reason: nil)
            ]
        )
    }

    @Test("QUIT")
    func quit() throws {
        #expect(
            try events(":bob!u@h QUIT :Ping timeout").dropFirst() == [
                .quit(who: user("bob"), reason: "Ping timeout")
            ]
        )
    }

    @Test("NICK")
    func nickChange() throws {
        #expect(
            try events(":bob!u@h NICK :robert").dropFirst() == [
                .nickChanged(who: user("bob"), newNick: "robert")
            ]
        )
    }

    @Test("KICK carries the kicker and the kicked separately")
    func kick() throws {
        #expect(
            try events(":bob!u@h KICK #swift carol :behave").dropFirst() == [
                .kicked(
                    channel: channel("#swift"),
                    by: user("bob"),
                    nick: "carol",
                    reason: "behave"
                )
            ]
        )
    }

    @Test("TOPIC")
    func topic() throws {
        #expect(
            try events(":bob!u@h TOPIC #swift :new topic").dropFirst() == [
                .topicChanged(channel: channel("#swift"), who: user("bob"), topic: "new topic")
            ]
        )
    }

    /// The arguments are reported unparsed: knowing that `+l` takes a number and `+m`
    /// does not needs `CHANMODES` and the channel state, which is prompt 8's.
    @Test("MODE reports its arguments without interpreting them")
    func mode() throws {
        #expect(
            try events(":bob!u@h MODE #swift +ol carol 50").dropFirst() == [
                .modeChanged(
                    target: .channel(channel("#swift")),
                    who: user("bob"),
                    arguments: ["+ol", "carol", "50"]
                )
            ]
        )
    }

    @Test("a server-sourced MODE on a nick is a user mode change")
    func userMode() throws {
        #expect(
            try events(":irc.example.org MODE alice :+i").dropFirst() == [
                .modeChanged(
                    target: .nick(IRCNick("alice", mapping: .ascii)),
                    who: .server("irc.example.org"),
                    arguments: ["+i"]
                )
            ]
        )
    }

    // MARK: - Numerics

    @Test("NAMES replies are split into their nicks")
    func namesReply() throws {
        #expect(
            try events(":irc.example.org 353 alice = #swift :@bob +carol dave").dropFirst() == [
                .namesReply(channel: channel("#swift"), names: ["@bob", "+carol", "dave"])
            ]
        )
        #expect(
            try events(":irc.example.org 366 alice #swift :End of /NAMES list").dropFirst() == [
                .endOfNames(channel: channel("#swift"))
            ]
        )
    }

    /// Anything without a specific event arrives as `.numeric`, so a status window can
    /// render the server's own words without a case per code.
    @Test("an unhandled numeric becomes .numeric")
    func genericNumeric() throws {
        #expect(
            try events(":irc.example.org 372 alice :- welcome to the MOTD").dropFirst() == [
                .numeric(code: 372, parameters: ["alice", "- welcome to the MOTD"])
            ]
        )
        #expect(
            try events(":irc.example.org 433 * alice :Nickname is already in use").dropFirst()
                == [
                    .numeric(
                        code: 433,
                        parameters: ["*", "alice", "Nickname is already in use"]
                    )
                ]
        )
    }

    /// The three whose content another event already carries in full.
    @Test("001, 353 and 366 do not also emit .numeric")
    func numericsWithSpecificEvents() throws {
        #expect(try events(":irc.example.org 001 alice :Welcome").count == 1)
        #expect(
            try !events(":irc.example.org 353 alice = #swift :bob").contains {
                if case .numeric = $0 { true } else { false }
            }
        )
        #expect(
            try !events(":irc.example.org 366 alice #swift :End").contains {
                if case .numeric = $0 { true } else { false }
            }
        )
        // But everything around them does. Three digits, always — `2` is a verb, not a
        // numeric, which is prompt 3's rule and easy to forget when writing a fixture.
        for code in ["002", "003", "004", "005", "372", "376"] {
            let line = ":irc.example.org \(code) alice :text"
            #expect(try events(line).contains { if case .numeric = $0 { true } else { false } })
        }
    }

    @Test("a malformed line degrades to .raw rather than a wrong event")
    func malformedLines() throws {
        // No source, so there is no one to attribute the join to.
        #expect(try events("JOIN #swift").count == 1)
        // No channel.
        #expect(try events(":bob!u@h JOIN").count == 1)
        // A 353 too short to name a channel is still shown, as a plain numeric, rather
        // than vanishing because of its code.
        #expect(try events(":irc.example.org 353 alice").count == 2)  // .raw plus .numeric
        #expect(
            try events(":irc.example.org 353 alice").last
                == .numeric(code: 353, parameters: ["alice"])
        )
    }

    // MARK: - Casemapping

    /// The channel in the event compares under the server's declared mapping, so a
    /// consumer keying a dictionary by it cannot accidentally create two windows.
    @Test("names in events use the server's casemapping")
    func casemappingApplies() throws {
        guard case .joined(let joined, _) = try #require(try events(":bob!u@h JOIN #Swift").last)
        else {
            Issue.record("expected a join event")
            return
        }
        #expect(joined == channel("#swift"))
        #expect(joined.raw == "#Swift")  // Display case is preserved.
    }
}
