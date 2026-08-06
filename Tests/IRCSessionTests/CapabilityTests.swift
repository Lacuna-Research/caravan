import IRCProtocol
import Testing

@testable import IRCSession

/// `CAP` parsing and the set it maintains.
///
/// Pure, and worth being pure: the awkward shapes — a multiline `LS`, a `-cap` inside an
/// `ACK`, a `name=value` token whose value contains an `=` — are the ones a live server
/// produces once a year and a test produces on demand.
@Suite("Capabilities")
struct CapabilityTests {
    private func parse(_ line: String) -> CapabilityCommand? {
        IRCMessage(line: line).flatMap(CapabilityCommand.init(message:))
    }

    // MARK: - Parsing

    @Test("a plain LS lists what is on offer")
    func simpleLS() throws {
        let command = try #require(parse(":s CAP * LS :multi-prefix sasl away-notify"))
        #expect(command.subcommand == .ls)
        #expect(!command.isContinued)
        #expect(command.tokens.map(\.name) == ["multi-prefix", "sasl", "away-notify"])
        #expect(command.tokens.allSatisfy { $0.value == nil })
    }

    @Test("a value survives, including one containing an equals sign")
    func valuedTokens() throws {
        let command = try #require(parse(":s CAP * LS :sasl=PLAIN,EXTERNAL draft/x=a=b"))
        #expect(command.tokens[0].value == "PLAIN,EXTERNAL")
        // The split is on the *first* `=`, so a value may contain more of them.
        #expect(command.tokens[1].value == "a=b")
    }

    /// The `*` is the whole reason `LS` cannot be acted on line by line: asking for what
    /// the first line offered would ask for a subset of what the server has.
    @Test("a continued LS is marked as such and its tokens still parse")
    func multilineLS() throws {
        let first = try #require(parse(":s CAP * LS * :multi-prefix sasl=PLAIN"))
        #expect(first.isContinued)
        #expect(first.tokens.map(\.name) == ["multi-prefix", "sasl"])

        let last = try #require(parse(":s CAP * LS :server-time"))
        #expect(!last.isContinued)
    }

    @Test("an ACK can turn a capability off, with a leading minus")
    func negativeAck() throws {
        let command = try #require(parse(":s CAP alice ACK :multi-prefix -echo-message"))
        #expect(command.subcommand == .ack)
        #expect(command.tokens[0].isDisabled == false)
        #expect(command.tokens[1].name == "echo-message")
        #expect(command.tokens[1].isDisabled)
    }

    @Test("an unknown subcommand is not a capability command")
    func unknownSubcommand() {
        #expect(parse(":s CAP * WOBBLE :x") == nil)
        #expect(parse(":s CAP") == nil)
        #expect(parse(":s NOTICE * :not a cap line") == nil)
    }

    @Test("every subcommand is recognised")
    func subcommands() throws {
        for (token, expected) in [
            ("LS", CapabilityCommand.Subcommand.ls), ("LIST", .list), ("ACK", .ack),
            ("NAK", .nak), ("NEW", .new), ("DEL", .del),
        ] {
            #expect(try #require(parse(":s CAP * \(token) :x")).subcommand == expected)
        }
    }

    // MARK: - The set

    @Test("advertising then acknowledging enables, and a minus disables")
    func lifecycle() throws {
        var capabilities = NegotiatedCapabilities()
        capabilities.advertise(try #require(parse(":s CAP * LS :multi-prefix echo-message")).tokens)
        #expect(capabilities.isAvailable(.multiPrefix))
        #expect(!capabilities.isEnabled(.multiPrefix))

        capabilities.acknowledge(try #require(parse(":s CAP a ACK :multi-prefix")).tokens)
        #expect(capabilities.isEnabled(.multiPrefix))
        #expect(!capabilities.isEnabled(.echoMessage))

        capabilities.acknowledge(try #require(parse(":s CAP a ACK :-multi-prefix")).tokens)
        #expect(!capabilities.isEnabled(.multiPrefix))
    }

    /// `cap-notify`'s `DEL`. A capability that goes away must stop being *enabled* too, or
    /// every consumer keeps believing in something the server has withdrawn.
    @Test("DEL removes a capability from both the offer and the enabled set")
    func withdrawal() throws {
        var capabilities = NegotiatedCapabilities()
        capabilities.advertise(try #require(parse(":s CAP * LS :sasl away-notify")).tokens)
        capabilities.acknowledge(try #require(parse(":s CAP a ACK :away-notify")).tokens)
        capabilities.withdraw(try #require(parse(":s CAP a DEL :away-notify")).tokens)
        #expect(!capabilities.isAvailable(.awayNotify))
        #expect(!capabilities.isEnabled(.awayNotify))
    }

    @Test("LIST replaces the enabled set outright")
    func listReplaces() throws {
        var capabilities = NegotiatedCapabilities()
        capabilities.acknowledge(try #require(parse(":s CAP a ACK :multi-prefix sasl")).tokens)
        capabilities.replaceEnabled(try #require(parse(":s CAP a LIST :server-time")).tokens)
        #expect(capabilities.enabledNames == ["server-time"])
    }

    // MARK: - SASL mechanisms

    @Test("the mechanism list is read off the sasl token")
    func mechanisms() throws {
        var capabilities = NegotiatedCapabilities()
        capabilities.advertise(
            try #require(parse(":s CAP * LS :sasl=PLAIN,external,SCRAM-SHA-256")).tokens
        )
        #expect(capabilities.saslMechanisms == ["PLAIN", "EXTERNAL", "SCRAM-SHA-256"])
    }

    /// The pre-3.2 spelling. A bare `sasl` means `PLAIN` on every server that sends it, and
    /// reading it as "no mechanisms" would refuse to authenticate against a working server.
    @Test("a bare sasl token means PLAIN")
    func bareSASL() throws {
        var capabilities = NegotiatedCapabilities()
        capabilities.advertise(try #require(parse(":s CAP * LS :sasl")).tokens)
        #expect(capabilities.saslMechanisms == ["PLAIN"])
    }

    @Test("a server offering no sasl offers no mechanisms")
    func noSASL() {
        #expect(NegotiatedCapabilities().saslMechanisms.isEmpty)
    }
}
