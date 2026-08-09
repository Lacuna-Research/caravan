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
                    isAction: false,
                    tags: IRCTags()
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
                    isAction: false,
                    tags: IRCTags()
                )
            ]
        )
    }

    @Test("NOTICE is distinguished from PRIVMSG")
    func notice() throws {
        guard
            case .message(_, _, _, let kind, _, _) = try #require(
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
                    isAction: true,
                    tags: IRCTags()
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

    // MARK: - CTCP

    /// A `VERSION` request is not something anybody said. It used to arrive as an ordinary
    /// message and render as control characters in a channel window.
    @Test("a CTCP request in a PRIVMSG is a request, not a message")
    func ctcpRequest() throws {
        #expect(
            try events(":bob!u@h PRIVMSG alice :\u{01}VERSION\u{01}").dropFirst() == [
                .ctcpRequest(
                    target: .nick(IRCNick("alice", mapping: .ascii)),
                    sender: user("bob"),
                    request: CTCPMessage(command: "VERSION"),
                    tags: IRCTags()
                )
            ]
        )
    }

    /// The `PRIVMSG`/`NOTICE` split is the only thing standing between two clients and an
    /// infinite exchange, so it decides which case this is.
    @Test("a CTCP in a NOTICE is a reply")
    func ctcpReply() throws {
        #expect(
            try events(":bob!u@h NOTICE alice :\u{01}VERSION mIRC v7.75\u{01}").dropFirst() == [
                .ctcpReply(
                    target: .nick(IRCNick("alice", mapping: .ascii)),
                    sender: user("bob"),
                    reply: CTCPMessage(command: "VERSION", argument: "mIRC v7.75"),
                    tags: IRCTags()
                )
            ]
        )
    }

    /// `ACTION` is a message wearing a CTCP's wrapper, and stays one.
    @Test("ACTION is a message, never a request")
    func actionIsNotARequest() throws {
        let events = try events(":bob!u@h PRIVMSG #swift :\u{01}ACTION waves\u{01}").dropFirst()
        #expect(
            events == [
                .message(
                    target: .channel(channel("#swift")),
                    sender: user("bob"),
                    text: "waves",
                    kind: .privmsg,
                    isAction: true,
                    tags: IRCTags()
                )
            ]
        )
    }

    /// A channel-wide `VERSION` is one person asking; the target says where it came in.
    @Test("a CTCP aimed at a channel keeps the channel as its target")
    func ctcpToChannel() throws {
        guard
            case .ctcpRequest(let target, _, let request, _) = try #require(
                try events(":bob!u@h PRIVMSG #swift :\u{01}PING 42\u{01}").last
            )
        else {
            Issue.record("expected a CTCP request")
            return
        }
        #expect(target == .channel(channel("#swift")))
        #expect(request.summary == "PING 42")
    }

    /// A stray `\u{01}` in a paste is a control character, not a request.
    @Test("a delimiter that is not leading leaves an ordinary message")
    func strayDelimiter() throws {
        guard
            case .message(_, _, let text, _, let isAction, _) = try #require(
                try events(":bob!u@h PRIVMSG #swift :hello \u{01}VERSION\u{01}").last
            )
        else {
            Issue.record("expected a message event")
            return
        }
        #expect(text == "hello \u{01}VERSION\u{01}")
        #expect(!isAction)
    }

    /// `@#swift` addresses the channel's operators. It is still the channel's window.
    @Test("a STATUSMSG prefix does not turn a channel into a nick")
    func statusMessagePrefix() throws {
        guard
            case .message(let target, _, _, _, _, _) = try #require(
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
                .joined(channel: channel("#swift"), who: user("bob"), account: nil, realName: nil)
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

    /// `PREFIX` says `o` takes a nick and `CHANMODES` says `l` takes a number when set,
    /// which is the only way a mode string can be split at all.
    @Test("MODE is split into its individual changes")
    func mode() throws {
        #expect(
            try events(":bob!u@h MODE #swift +ol carol 50").dropFirst() == [
                .modeChanged(
                    target: .channel(channel("#swift")),
                    who: user("bob"),
                    changes: [
                        ModeChange(isSet: true, mode: "o", argument: "carol"),
                        ModeChange(isSet: true, mode: "l", argument: "50"),
                    ]
                )
            ]
        )
    }

    /// User modes never take an argument, and treating them as if they might would eat
    /// the next parameter of a line that has none.
    @Test("a server-sourced MODE on a nick is a user mode change")
    func userMode() throws {
        #expect(
            try events(":irc.example.org MODE alice :+i").dropFirst() == [
                .modeChanged(
                    target: .nick(IRCNick("alice", mapping: .ascii)),
                    who: .server("irc.example.org"),
                    changes: [ModeChange(isSet: true, mode: "i")]
                )
            ]
        )
    }

    @Test("324 reports the channel's standing modes")
    func channelModeReply() throws {
        #expect(
            try events(":irc.example.org 324 alice #swift +ntl 50").dropFirst() == [
                .channelModes(
                    channel: channel("#swift"),
                    changes: [
                        ModeChange(isSet: true, mode: "n"),
                        ModeChange(isSet: true, mode: "t"),
                        ModeChange(isSet: true, mode: "l", argument: "50"),
                    ]
                )
            ]
        )
    }

    // MARK: - Topic numerics

    @Test("332 is the standing topic, with no one to attribute it to yet")
    func topicReply() throws {
        #expect(
            try events(":irc.example.org 332 alice #swift :a topic").dropFirst() == [
                .topicChanged(channel: channel("#swift"), who: nil, topic: "a topic")
            ]
        )
    }

    /// One representation of "no topic", not two: an empty topic is what a `TOPIC`
    /// clearing one sends, so 331 says the same thing the same way.
    @Test("331 is an empty topic rather than an event of its own")
    func noTopicReply() throws {
        #expect(
            try events(":irc.example.org 331 alice #swift :No topic is set").dropFirst() == [
                .topicChanged(channel: channel("#swift"), who: nil, topic: "")
            ]
        )
    }

    @Test("333 attributes the standing topic")
    func topicAuthorReply() throws {
        #expect(
            try events(":irc.example.org 333 alice #swift bob 1700000000").dropFirst() == [
                .topicAuthor(channel: channel("#swift"), nick: "bob", setAt: 1_700_000_000)
            ]
        )
    }

    /// Some servers send a full `nick!user@host` here, and some omit the timestamp.
    @Test("333 tolerates a full source and a missing timestamp")
    func topicAuthorVariants() throws {
        #expect(
            try events(":irc.example.org 333 alice #swift bob!u@h").dropFirst() == [
                .topicAuthor(channel: channel("#swift"), nick: "bob", setAt: nil)
            ]
        )
    }

    // MARK: - Join failures

    @Test(
        "a join failure becomes a typed error rather than a bare numeric",
        arguments: [
            (UInt16(471), JoinFailure.channelIsFull),
            (473, .inviteOnly),
            (474, .banned),
            (475, .badKey),
            (476, .badChannelMask),
            (477, .needsRegisteredNick),
        ]
    )
    func joinFailures(code: UInt16, reason: JoinFailure) throws {
        #expect(
            try events(":irc.example.org \(code) alice #swift :Cannot join channel").dropFirst()
                == [
                    .joinFailed(
                        channel: channel("#swift"),
                        reason: reason,
                        text: "Cannot join channel"
                    )
                ]
        )
    }

    /// Suppression is conditional on a specific event actually being produced. A join
    /// failure too short to name a channel still reaches the status window.
    @Test("a truncated join failure falls through to .numeric rather than vanishing")
    func truncatedJoinFailure() throws {
        #expect(
            try events(":irc.example.org 475 alice").dropFirst() == [
                .numeric(code: 475, parameters: ["alice"])
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

    // MARK: - The channel list

    @Test("322 becomes an entry, with its topic")
    func channelListEntry() throws {
        #expect(
            try events(":irc.example.org 322 alice #swift 214 :[+nt] Swift talk").last
                == .channelListEntry(
                    channel: channel("#swift"),
                    members: 214,
                    topic: "[+nt] Swift talk"
                )
        )
    }

    /// The mode flags some servers prefix are left alone deliberately: they are information,
    /// and they are what the server said.
    @Test("a missing topic is an empty one, not a missing row")
    func channelListWithoutTopic() throws {
        #expect(
            try events(":irc.example.org 322 alice #quiet 3").last
                == .channelListEntry(channel: channel("#quiet"), members: 3, topic: "")
        )
    }

    /// `*` is the server declining to say which channel this is — there is nothing to show
    /// for it and nothing to join, so it falls through to a plain numeric.
    @Test("a `*` channel is not an entry")
    func channelListMasked() throws {
        let last = try events(":irc.example.org 322 alice * 5 :hidden").last
        #expect(last == .numeric(code: 322, parameters: ["alice", "*", "5", "hidden"]))
    }

    /// A channel hidden because a server padded a field is worse than one sorted wrong.
    @Test("a count that is not a number is zero, and the row survives")
    func channelListJunkCount() throws {
        #expect(
            try events(":irc.example.org 322 alice #odd ??? :topic").last
                == .channelListEntry(channel: channel("#odd"), members: 0, topic: "topic")
        )
    }

    @Test("323 ends the list, and 321 starts nothing and is not shown")
    func channelListEnd() throws {
        #expect(try events(":irc.example.org 323 alice :End of /LIST").last == .channelListEnd)
        // 321 is column headings for a table the client draws itself. Nothing may depend on
        // it — several servers skip it — so it starts nothing, and it is not shown either:
        // `.raw` and nothing else. A live `/list` otherwise leaves one stray
        // "Channel Users  Name" in the status window.
        let start = try events(":irc.example.org 321 alice Channel :Users  Name")
        #expect(start.count == 1)
        if case .raw? = start.first {} else { Issue.record("expected only .raw, got \(start)") }
    }

    // MARK: - Casemapping

    /// The channel in the event compares under the server's declared mapping, so a
    /// consumer keying a dictionary by it cannot accidentally create two windows.
    @Test("names in events use the server's casemapping")
    func casemappingApplies() throws {
        guard
            case .joined(let joined, _, _, _) = try #require(
                try events(":bob!u@h JOIN #Swift").last
            )
        else {
            Issue.record("expected a join event")
            return
        }
        #expect(joined == channel("#swift"))
        #expect(joined.raw == "#Swift")  // Display case is preserved.
    }
}
