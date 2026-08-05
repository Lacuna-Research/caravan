import Testing

@testable import IRCProtocol

@Suite("Parsing edge cases")
struct ParsingEdgeCaseTests {
    @Test("empty trailing parameter is a parameter, not an absence")
    func emptyTrailing() throws {
        let message = try #require(IRCMessage(line: "PRIVMSG #chan :"))
        #expect(message.parameters == ["#chan", ""])
        // And it must survive the round trip, since dropping it changes the message.
        #expect(message.wireForm == "PRIVMSG #chan :")
    }

    @Test("trailing that is just a colon yields a single colon")
    func trailingIsColon() throws {
        let message = try #require(IRCMessage(line: "PRIVMSG #chan ::"))
        #expect(message.parameters == ["#chan", ":"])
        #expect(message.wireForm == "PRIVMSG #chan ::")
    }

    @Test("trailing keeps interior spaces and leading spaces")
    func trailingKeepsSpaces() throws {
        let message = try #require(IRCMessage(line: "PRIVMSG #chan :  hello   world  "))
        #expect(message.parameters == ["#chan", "  hello   world  "])
        #expect(message.wireForm == "PRIVMSG #chan :  hello   world  ")
    }

    @Test("runs of spaces between parameters collapse")
    func collapsesSpaceRuns() throws {
        let message = try #require(IRCMessage(line: "foo   bar     baz"))
        #expect(message.parameters == ["bar", "baz"])
    }

    @Test("a valueless tag is distinguishable from an empty-valued one")
    func valuelessVersusEmptyTag() throws {
        let valueless = try #require(IRCMessage(line: "@a foo"))
        let empty = try #require(IRCMessage(line: "@a= foo"))

        #expect(valueless.tags.tags == [IRCTag(key: "a", value: nil)])
        #expect(empty.tags.tags == [IRCTag(key: "a", value: "")])
        #expect(valueless.tags != empty.tags)

        // IRCv3 says they mean the same thing, so the accessor flattens them.
        #expect(valueless.tags.value(for: "a") == "")
        #expect(empty.tags.value(for: "a") == "")
    }

    @Test("later duplicate tags win")
    func duplicateTagsLastWins() throws {
        let message = try #require(IRCMessage(line: "@x=1;y=2;x=3 foo"))
        #expect(message.tags.value(for: "x") == "3")
        // Both are still present in wire order — the trace shows what arrived.
        #expect(message.tags.count == 3)
    }

    @Test("unknown tag escapes drop the backslash and keep the character")
    func unknownEscape() {
        #expect(IRCTags.unescape("value\\1") == "value1")
        #expect(IRCTags.unescape("a\\qb") == "aqb")
    }

    @Test("a lone trailing backslash is dropped")
    func loneTrailingBackslash() {
        #expect(IRCTags.unescape("value1\\") == "value1")
    }

    @Test("tag escaping round-trips, including a bare CRLF")
    func tagEscapeRoundTrip() {
        // The grapheme-cluster case: Swift treats CR LF as one Character, so escaping
        // by Character silently lets it through and truncates the line on the wire.
        let awkward = "\\\\;\\s \r\n"
        #expect(IRCTags.unescape(IRCTags.escape(awkward)) == awkward)
        #expect(!IRCTags.escape(awkward).contains("\r"))
        #expect(!IRCTags.escape(awkward).contains("\n"))
    }

    @Test("source with no user parses and serializes canonically")
    func sourceWithoutUser() throws {
        let message = try #require(IRCMessage(line: ":coolguy@127.0.0.1 PRIVMSG #x :hi"))
        #expect(message.source?.nick == "coolguy")
        #expect(message.source?.user == nil)
        #expect(message.source?.host == "127.0.0.1")
        #expect(message.wireForm == ":coolguy@127.0.0.1 PRIVMSG #x hi")
    }

    @Test("source with no host parses and serializes canonically")
    func sourceWithoutHost() throws {
        let message = try #require(IRCMessage(line: ":coolguy!ag PRIVMSG #x :hi"))
        #expect(message.source?.user == "ag")
        #expect(message.source?.host == nil)
        #expect(message.wireForm == ":coolguy!ag PRIVMSG #x hi")
    }

    @Test("a dotted bare source is a server, an undotted one is a nick")
    func serverVersusNick() {
        #expect(IRCSource(prefix: "irc.example.com") == .server("irc.example.com"))
        #expect(IRCSource(prefix: "coolguy") == .user(nick: "coolguy", user: nil, host: nil))
    }

    @Test(
        "non-ASCII and control bytes in the trailing parameter survive intact",
        arguments: [
            "PRIVMSG #chan :héllo wörld",
            "PRIVMSG #chan :\u{0003}5colour\u{000F} reset",
            "PRIVMSG #chan :\u{0002}bold\u{0002} and \u{001F}underline\u{001F}",
            "PRIVMSG #chan :日本語のテキスト",
            "PRIVMSG #chan :emoji 👩‍👩‍👧‍👦 family",
            ":coolguy!ag@net\u{0003}5w\u{0003}ork.admin PRIVMSG #chan :hi",
        ]
    )
    func preservesEightBitAndControlCharacters(line: String) throws {
        let message = try #require(IRCMessage(line: line))
        let reparsed = try #require(IRCMessage(line: message.wireForm))
        #expect(reparsed == message, "content changed passing through serialization")
        #expect(reparsed.parameters == message.parameters)
    }

    @Test("a line with no command does not parse")
    func noCommand() {
        #expect(IRCMessage(line: "") == nil)
        #expect(IRCMessage(line: "   ") == nil)
        #expect(IRCMessage(line: "@only=tags") == nil)
        #expect(IRCMessage(line: ":only.source") == nil)
    }

    @Test("three ASCII digits are a numeric, other digit strings are verbs")
    func numericClassification() {
        #expect(IRCCommand(token: "001") == .numeric(1))
        #expect(IRCCommand(token: "376") == .numeric(376))
        #expect(IRCCommand(token: "01") == .verb("01"))
        #expect(IRCCommand(token: "0001") == .verb("0001"))
        #expect(IRCCommand(token: "PRIVMSG") == .verb("PRIVMSG"))
    }

    @Test("numerics keep three-digit zero padding when serialized")
    func numericPadding() {
        #expect(IRCCommand.numeric(1).wireForm == "001")
        #expect(IRCCommand.numeric(42).wireForm == "042")
        #expect(IRCCommand.numeric(376).wireForm == "376")
        let message = IRCMessage(command: .numeric(1), parameters: ["alice", "Welcome home"])
        #expect(message.wireForm == "001 alice :Welcome home")
    }

    @Test(
        "parameters that cannot be plain are serialized as trailing",
        arguments: [
            ([""], "PRIVMSG :"),
            ([" "], "PRIVMSG : "),
            (["a b"], "PRIVMSG :a b"),
            ([":leading"], "PRIVMSG ::leading"),
            (["plain"], "PRIVMSG plain"),
        ] as [([String], String)]
    )
    func trailingSerializationRules(parameters: [String], expected: String) {
        #expect(IRCMessage(verb: "PRIVMSG", parameters: parameters).wireForm == expected)
    }

    /// Serialization is canonical, not byte-preserving: `PING :12345` becomes
    /// `PING 12345` because the colon is only required when a parameter is empty,
    /// contains a space, or begins with `:`. The property worth holding is that
    /// serializing and reparsing changes nothing — the raw line is kept separately by
    /// the trace buffer for anyone who needs the bytes exactly as they arrived.
    @Test(
        "serializing and reparsing is a fixed point",
        arguments: [
            "PING :12345",
            "JOIN #dev",
            ":alice!a@h PRIVMSG #dev :hello there",
            "@time=2026-08-04T12:00:00.000Z :s.example 001 alice :Welcome home",
            "@a;b=c :nick!u@h COMMAND p1 p2 :trailing with spaces",
            "CAP REQ :multi-prefix sasl",
            "PRIVMSG #chan :",
            "PRIVMSG #chan ::",
        ]
    )
    func serializationIsAFixedPoint(line: String) throws {
        let once = try #require(IRCMessage(line: line))
        let twice = try #require(IRCMessage(line: once.wireForm))
        #expect(twice == once)
        #expect(twice.wireForm == once.wireForm)
    }

    @Test(
        "lines already in canonical form round-trip byte for byte",
        arguments: [
            "JOIN #dev",
            "PING 12345",
            ":alice!a@h PRIVMSG #dev :hello there",
            "@a;b=c :nick!u@h COMMAND p1 p2 :trailing with spaces",
            "PRIVMSG #chan :",
            "PRIVMSG #chan ::",
        ]
    )
    func canonicalLinesRoundTripExactly(line: String) throws {
        #expect(try #require(IRCMessage(line: line)).wireForm == line)
    }
}
