import IRCProtocol
import Testing

@testable import IRCSession

@Suite("ISUPPORT")
struct ServerCapabilitiesTests {
    private func capabilities(_ tokens: String...) -> ServerCapabilities {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: tokens)
        return capabilities
    }

    @Test("defaults are the protocol's, not guesses")
    func defaults() {
        let capabilities = ServerCapabilities()
        #expect(capabilities.caseMapping == .rfc1459)
        #expect(capabilities.channelTypes == ["#", "&"])
        #expect(capabilities.prefixes.map(\.prefix) == ["@", "+"])
        #expect(capabilities.nickLength == 9)
        #expect(capabilities.channelLength == 200)
        #expect(capabilities.topicLength == nil)
    }

    @Test("PREFIX maps modes to prefixes in rank order")
    func prefix() {
        let capabilities = capabilities("PREFIX=(qaohv)~&@%+")
        #expect(capabilities.prefixes.map(\.mode) == ["q", "a", "o", "h", "v"])
        #expect(capabilities.prefixes.map(\.prefix) == ["~", "&", "@", "%", "+"])
        #expect(capabilities.prefix(forMode: "h") == "%")
        #expect(capabilities.mode(forPrefix: "&") == "a")
        // Rank drives nick-list ordering in prompt 8, so it must come from the server's
        // declared order rather than a hardcoded @%+.
        #expect(capabilities.rank(ofPrefix: "~") == 0)
        #expect(capabilities.rank(ofPrefix: "+") == 4)
        #expect(capabilities.rank(ofPrefix: "!") == nil)
    }

    @Test("an empty PREFIX means no membership prefixes at all")
    func emptyPrefix() {
        #expect(capabilities("PREFIX=").prefixes.isEmpty)
    }

    @Test("CHANMODES splits into its four groups")
    func chanModes() {
        let modes = capabilities("CHANMODES=beI,k,l,imnpst").channelModes
        #expect(modes.lists == ["b", "e", "I"])
        #expect(modes.alwaysArgument == ["k"])
        #expect(modes.argumentWhenSet == ["l"])
        #expect(modes.noArgument == ["i", "m", "n", "p", "s", "t"])
    }

    @Test("a CHANMODES with missing groups leaves them empty rather than shifting them")
    func partialChanModes() {
        let modes = capabilities("CHANMODES=b,,,mnt").channelModes
        #expect(modes.lists == ["b"])
        #expect(modes.alwaysArgument.isEmpty)
        #expect(modes.argumentWhenSet.isEmpty)
        #expect(modes.noArgument == ["m", "n", "t"])
    }

    @Test("TARGMAX reads limits, and an empty one means unlimited")
    func targetMaximums() {
        let maximums = capabilities("TARGMAX=PRIVMSG:4,NOTICE:3,JOIN:").targetMaximums
        #expect(maximums["PRIVMSG"] == 4)
        #expect(maximums["NOTICE"] == 3)
        // Present as a key, with no limit — distinct from being absent entirely.
        #expect(maximums["JOIN"] == .some(nil))
        #expect(maximums["PART"] == nil)
    }

    @Test("CASEMAPPING selects the mapping used downstream")
    func caseMapping() {
        #expect(capabilities("CASEMAPPING=ascii").caseMapping == .ascii)
        #expect(capabilities("CASEMAPPING=strict-rfc1459").caseMapping == .rfc1459Strict)
        // An unknown mapping falls back rather than guessing.
        #expect(capabilities("CASEMAPPING=klingon").caseMapping == .rfc1459)
    }

    @Test("numeric and text tokens are read")
    func scalarTokens() {
        let capabilities = capabilities(
            "NETWORK=Libera.Chat",
            "NICKLEN=16",
            "CHANNELLEN=64",
            "TOPICLEN=390",
            "MODES=4",
            "STATUSMSG=@+",
            "CHANTYPES=#"
        )
        #expect(capabilities.network == "Libera.Chat")
        #expect(capabilities.nickLength == 16)
        #expect(capabilities.channelLength == 64)
        #expect(capabilities.topicLength == 390)
        #expect(capabilities.maximumModesPerCommand == 4)
        #expect(capabilities.statusMessagePrefixes == ["@", "+"])
        #expect(capabilities.isChannelName("#swift"))
        #expect(!capabilities.isChannelName("&swift"))
    }

    @Test("MONITOR is supported with or without a limit")
    func monitor() {
        #expect(capabilities("MONITOR=100").supportsMonitor)
        #expect(capabilities("MONITOR=100").monitorLimit == 100)
        #expect(capabilities("MONITOR").supportsMonitor)
        #expect(capabilities("MONITOR").monitorLimit == nil)
        #expect(!ServerCapabilities().supportsMonitor)
    }

    /// A valueless token is not the same as an empty-valued one, and neither may be
    /// mistaken for an absent token.
    @Test("a valueless token is distinct from an empty value")
    func valuelessVersusEmpty() {
        let valueless = capabilities("SAFELIST")
        #expect(valueless.rawTokens["SAFELIST"] == .some(nil))
        #expect(valueless.rawTokens.keys.contains("SAFELIST"))

        let empty = capabilities("SAFELIST=")
        #expect(empty.rawTokens["SAFELIST"] == "")
    }

    @Test("unknown tokens are kept verbatim rather than discarded")
    func unknownTokensKept() {
        let capabilities = capabilities("WHOX", "ELIST=CTU", "SOMETHINGNEW=42")
        #expect(capabilities.rawTokens["ELIST"] == "CTU")
        #expect(capabilities.rawTokens["SOMETHINGNEW"] == "42")
        #expect(capabilities.rawTokens.keys.contains("WHOX"))
    }

    @Test("negation removes a token and restores its default")
    func negation() {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: ["NICKLEN=30", "CHANTYPES=#", "ELIST=CTU"])
        #expect(capabilities.nickLength == 30)

        capabilities.apply(tokens: ["-NICKLEN", "-CHANTYPES", "-ELIST"])
        #expect(capabilities.nickLength == 9)
        #expect(capabilities.channelTypes == ["#", "&"])
        #expect(capabilities.rawTokens["ELIST"] == nil)
    }

    @Test("token names are case-insensitive")
    func caseInsensitiveNames() {
        #expect(capabilities("nicklen=25").nickLength == 25)
    }

    /// ISUPPORT escapes a space as `\x20`, which is the only way a NETWORK name with a
    /// space in it can survive the wire.
    @Test("values are unescaped")
    func unescaping() {
        #expect(capabilities("NETWORK=Some\\x20Network").network == "Some Network")
        #expect(capabilities("FOO=a\\x5Cb").rawTokens["FOO"] == "a\\b")
        // A malformed escape is left as written rather than swallowed.
        #expect(capabilities("FOO=100\\x").rawTokens["FOO"] == "100\\x")
        #expect(capabilities("FOO=a\\xZZb").rawTokens["FOO"] == "a\\xZZb")
    }

    @Test("005 tokens exclude the nick and the trailing prose")
    func tokenExtraction() throws {
        let message = try #require(
            IRCMessage(
                line:
                    ":irc.example.org 005 alice CHANTYPES=# PREFIX=(ov)@+ :are supported by this server"
            )
        )
        #expect(
            ServerCapabilities.tokens(inISUPPORT: message) == ["CHANTYPES=#", "PREFIX=(ov)@+"]
        )
    }

    @Test("a short 005 yields no tokens rather than misreading the nick as one")
    func shortISUPPORT() throws {
        let message = try #require(IRCMessage(line: ":irc.example.org 005 alice"))
        #expect(ServerCapabilities.tokens(inISUPPORT: message).isEmpty)
    }
}
