import Testing

@testable import IRCProtocol

@Suite("Case mapping")
struct CaseMappingTests {
    @Test("ascii folds only A-Z")
    func asciiFolding() {
        #expect(IRCCaseMapping.ascii.foldedCase("CoolGuy") == "coolguy")
        // The Scandinavian pairs are untouched under ascii.
        #expect(IRCCaseMapping.ascii.foldedCase("Foo[]\\~") == "foo[]\\~")
        #expect(!IRCCaseMapping.ascii.equal("Foo[]", "foo{}"))
    }

    @Test("rfc1459 folds []\\~ onto {}|^")
    func rfc1459Folding() {
        #expect(IRCCaseMapping.rfc1459.foldedCase("Foo[]\\~") == "foo{}|^")
        #expect(IRCCaseMapping.rfc1459.equal("Foo[]", "foo{}"))
        #expect(IRCCaseMapping.rfc1459.equal("nick~", "nick^"))
    }

    @Test("strict-rfc1459 folds []\\ but leaves ~ alone")
    func strictFolding() {
        #expect(IRCCaseMapping.rfc1459Strict.foldedCase("Foo[]\\~") == "foo{}|~")
        #expect(IRCCaseMapping.rfc1459Strict.equal("Foo[]", "foo{}"))
        #expect(!IRCCaseMapping.rfc1459Strict.equal("nick~", "nick^"))
    }

    @Test("ISUPPORT tokens round-trip", arguments: IRCCaseMapping.allCases)
    func tokenRoundTrip(mapping: IRCCaseMapping) {
        #expect(IRCCaseMapping(token: mapping.token) == mapping)
        #expect(IRCCaseMapping(token: mapping.token.uppercased()) == mapping)
    }

    @Test("an unknown ISUPPORT token is rejected rather than guessed")
    func unknownToken() {
        #expect(IRCCaseMapping(token: "utf8-only") == nil)
        #expect(IRCCaseMapping(token: "") == nil)
    }

    @Test("non-ASCII text is left alone")
    func leavesUnicodeAlone() {
        #expect(IRCCaseMapping.rfc1459.foldedCase("Ünïcödé") == "Ünïcödé")
    }
}

@Suite("Case-insensitive names")
struct NameTests {
    /// The reason these types exist: a dictionary keyed by raw `String` would create
    /// two entries for one user on an rfc1459 server.
    @Test("nicks differing only by case map to one dictionary key")
    func nickDictionaryKey() {
        var members: [IRCNick: Int] = [:]
        members[IRCNick("Foo[]", mapping: .rfc1459)] = 1
        members[IRCNick("foo{}", mapping: .rfc1459)] = 2
        #expect(members.count == 1)
        #expect(members[IRCNick("FOO{}", mapping: .rfc1459)] == 2)
    }

    @Test("display case is preserved even though comparison ignores it")
    func preservesDisplayCase() {
        let nick = IRCNick("CoolGuy", mapping: .rfc1459)
        #expect(nick.raw == "CoolGuy")
        #expect(nick.description == "CoolGuy")
        #expect(nick == IRCNick("coolguy", mapping: .rfc1459))
    }

    @Test("names folded under different mappings are not interchangeable")
    func mappingParticipatesInEquality() {
        #expect(IRCNick("Foo[]", mapping: .rfc1459) != IRCNick("Foo[]", mapping: .ascii))
    }

    @Test("channel names compare case-insensitively and expose their prefix")
    func channelNames() {
        #expect(IRCChannelName("#Dev") == IRCChannelName("#dev"))
        #expect(IRCChannelName("#dev").prefix == "#")
        #expect(IRCChannelName("&local").prefix == "&")
    }

    @Test("ordering uses the folded form")
    func ordering() {
        let sorted = [IRCNick("charlie"), IRCNick("Alice"), IRCNick("bob")].sorted()
        #expect(sorted.map(\.raw) == ["Alice", "bob", "charlie"])
    }
}

@Suite("Mask matching")
struct MaskTests {
    @Test("star matches any run including empty")
    func starMatching() {
        #expect(IRCMask.matches(mask: "*", source: "a!b@c"))
        #expect(IRCMask.matches(mask: "a!*@c", source: "a!@c"))
        #expect(IRCMask.matches(mask: "*!*@*", source: "nick!user@host"))
    }

    @Test("question mark matches exactly one character")
    func questionMatching() {
        #expect(IRCMask.matches(mask: "a?c", source: "abc"))
        #expect(!IRCMask.matches(mask: "a?c", source: "ac"))
        #expect(!IRCMask.matches(mask: "a?c", source: "abbc"))
    }

    @Test("brackets are literal, not character classes")
    func bracketsAreLiteral() {
        #expect(IRCMask.matches(mask: "cool[guy]!*@*", source: "cool[guy]!a@host"))
        #expect(!IRCMask.matches(mask: "cool[guy]!*@*", source: "coolg!a@host"))
    }

    @Test("matching is casemapping-aware")
    func casemappingAware() {
        #expect(IRCMask.matches(mask: "NICK!*@*", source: "nick!u@h", mapping: .ascii))
        // [] and {} are the same character under rfc1459 but not under ascii.
        #expect(IRCMask.matches(mask: "foo[]!*@*", source: "foo{}!u@h", mapping: .rfc1459))
        #expect(!IRCMask.matches(mask: "foo[]!*@*", source: "foo{}!u@h", mapping: .ascii))
    }

    @Test("pathological masks terminate")
    func pathologicalMask() {
        // Naive recursive globbing goes exponential here; the iterative version does not.
        let source = String(repeating: "a", count: 200) + "!u@h"
        #expect(!IRCMask.matches(mask: "*a*a*a*a*a*a*b", source: source))
    }
}
