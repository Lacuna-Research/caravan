import IRCProtocol
import Testing

@testable import IRCSession

/// The rest of the command table, added in prompt 8.
///
/// The parser is pure, so the whole table runs without a socket and there is no reason not
/// to be exhaustive. Expectations are written as the wire lines that would go out, which
/// is the form a bug in this layer actually shows up as.
@Suite("Command table")
struct CommandTableTests {
    private static let parser: CommandParser = {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: [
            "CASEMAPPING=ascii", "CHANTYPES=#&", "PREFIX=(ov)@+", "MODES=3",
            "EXCEPTS", "INVEX",
        ])
        return CommandParser(capabilities: capabilities, pingToken: "1728394")
    }()

    private static let channel = Target(
        "#swift",
        capabilities: {
            var capabilities = ServerCapabilities()
            capabilities.apply(tokens: ["CASEMAPPING=ascii", "CHANTYPES=#&"])
            return capabilities
        }()
    )

    private func wire(_ input: String, in target: Target? = channel) -> [String] {
        Self.parser.actions(for: input, activeTarget: target).map { action in
            guard case .send(let message) = action else { return "NOT A SEND: \(action)" }
            return message.wireForm
        }
    }

    private func actions(_ input: String, in target: Target? = channel) -> [CommandAction] {
        Self.parser.actions(for: input, activeTarget: target)
    }

    private func error(_ input: String, in target: Target? = channel) throws -> String {
        let actions = Self.parser.actions(for: input, activeTarget: target)
        #expect(actions.count == 1, "expected exactly one error, got \(actions)")
        guard case .error(let message)? = actions.first else {
            throw ExpectedAnError(actions: actions)
        }
        return message
    }

    private struct ExpectedAnError: Error { let actions: [CommandAction] }

    // MARK: - Asking the server

    @Test("the query commands pass their arguments through as typed")
    func queries() {
        #expect(wire("/whois bob") == ["WHOIS bob"])
        // `/whois bob bob` asks bob's own server, which is how you get idle time.
        #expect(wire("/whois bob bob") == ["WHOIS bob bob"])
        #expect(wire("/whowas bob 5") == ["WHOWAS bob 5"])
        #expect(wire("/oper alice hunter2") == ["OPER alice hunter2"])
    }

    /// A bare `/who` in a channel asks about that channel, which is the only thing it
    /// could usefully mean.
    @Test("who and names default to the window's channel")
    func windowDefaults() throws {
        #expect(wire("/who") == ["WHO #swift"])
        #expect(wire("/who bob*") == ["WHO bob*"])
        #expect(wire("/names") == ["NAMES #swift"])
        #expect(wire("/names #other") == ["NAMES #other"])
        #expect(try error("/who", in: nil).contains("/who"))
    }

    // MARK: - Presence

    /// `/away` with no reason is how you come back, per the RFC.
    @Test("away and back are the same line")
    func away() {
        #expect(wire("/away") == ["AWAY"])
        #expect(wire("/back") == ["AWAY"])
        #expect(wire("/away making tea") == ["AWAY :making tea"])
    }

    // MARK: - Saying things

    @Test("say is a plain line, explicitly")
    func say() throws {
        #expect(wire("/say hello") == ["PRIVMSG #swift hello"])
        // The point of it: a line that begins with a slash, without doubling it.
        #expect(wire("/say /not-a-command") == ["PRIVMSG #swift /not-a-command"])
        #expect(try error("/say").contains("/say"))
    }

    /// The parser cannot know what the channels are, so it says what was asked for.
    @Test("amsg and ame are one action, not a run of sends")
    func amsg() throws {
        #expect(
            actions("/amsg back in five") == [.toAllChannels(text: "back in five", isAction: false)]
        )
        #expect(actions("/ame waves") == [.toAllChannels(text: "waves", isAction: true)])
        #expect(try error("/amsg").contains("/amsg"))
    }

    /// A request is a `PRIVMSG`. A `NOTICE` is a *reply*, and that split is the only thing
    /// stopping two clients answering each other forever.
    @Test("ctcp sends a request, never a reply")
    func ctcp() throws {
        let delimiter = "\u{01}"
        // No leading colon on the first two: `wireForm` marks a trailing parameter only
        // when it has to, and a wrapper with no space in it does not.
        #expect(wire("/ctcp bob VERSION") == ["PRIVMSG bob \(delimiter)VERSION\(delimiter)"])
        // Lower case in, upper case out: CTCP keywords are conventionally upper.
        #expect(wire("/ctcp bob time") == ["PRIVMSG bob \(delimiter)TIME\(delimiter)"])
        #expect(
            wire("/ctcp bob ping 42") == ["PRIVMSG bob :\(delimiter)PING 42\(delimiter)"]
        )
        #expect(try error("/ctcp bob").contains("/ctcp"))
    }

    @Test("ping carries the token it was given")
    func ping() throws {
        let delimiter = "\u{01}"
        #expect(wire("/ping bob") == ["PRIVMSG bob :\(delimiter)PING 1728394\(delimiter)"])
        #expect(try error("/ping").contains("/ping"))
    }

    // MARK: - The buffer

    @Test("clear and clearall are buffer actions, not wire lines")
    func clear() {
        #expect(actions("/clear") == [.clearScrollback(everywhere: false)])
        #expect(actions("/clearall") == [.clearScrollback(everywhere: true)])
    }

    // MARK: - Modes

    /// With no mode string `/mode` *asks* — which is the only way to read a channel's
    /// modes without changing them.
    @Test("mode with no arguments asks rather than sets")
    func modeAsks() {
        #expect(wire("/mode") == ["MODE #swift"])
        #expect(wire("/mode #other") == ["MODE #other"])
        #expect(wire("/mode +m") == ["MODE #swift +m"])
        #expect(wire("/mode #other +m") == ["MODE #other +m"])
        #expect(wire("/mode +k hunter2") == ["MODE #swift +k hunter2"])
        // A nick target, for user modes.
        #expect(wire("/mode alice +i") == ["MODE alice +i"])
    }

    /// One `MODE` line, not three — three would be three times the traffic and three times
    /// the flood risk, which is what `MODES=` exists to bound.
    @Test("op and friends batch several people into one line")
    func membershipBatching() {
        #expect(wire("/op alice") == ["MODE #swift +o alice"])
        #expect(wire("/op alice bob carol") == ["MODE #swift +ooo alice bob carol"])
        #expect(wire("/deop alice bob") == ["MODE #swift -oo alice bob"])
        #expect(wire("/voice alice") == ["MODE #swift +v alice"])
        #expect(wire("/devoice alice bob") == ["MODE #swift -vv alice bob"])
    }

    /// `MODES=3` on this server, so a fourth nick starts a second line.
    @Test("batches split at the server's MODES limit")
    func modesLimit() {
        #expect(
            wire("/op a b c d e") == [
                "MODE #swift +ooo a b c",
                "MODE #swift +oo d e",
            ]
        )
    }

    @Test("a channel may lead, for acting on another window")
    func explicitChannel() throws {
        #expect(wire("/op #other alice") == ["MODE #other +o alice"])
        #expect(try error("/op alice", in: nil).contains("/op"))
        #expect(try error("/op").contains("/op"))
    }

    /// The reason keeps its internal spacing, because it is a sentence a person wrote.
    @Test("kick takes an optional reason, verbatim")
    func kick() throws {
        #expect(wire("/kick bob") == ["KICK #swift bob"])
        #expect(wire("/kick bob be nicer") == ["KICK #swift bob :be nicer"])
        #expect(wire("/kick #other bob bye") == ["KICK #other bob bye"])
        #expect(try error("/kick").contains("/kick"))
    }

    /// The mask is the connection's to resolve, because `*!*@host` needs the roster.
    @Test("ban names a person and leaves the mask to be decided")
    func ban() throws {
        #expect(
            actions("/ban bob")
                == [.ban(channel: "#swift", subject: "bob", isSet: true, kickReason: nil)]
        )
        #expect(
            actions("/unban bob")
                == [.ban(channel: "#swift", subject: "bob", isSet: false, kickReason: nil)]
        )
        #expect(
            actions("/kickban bob spam")
                == [.ban(channel: "#swift", subject: "bob", isSet: true, kickReason: "spam")]
        )
        // A kickban with no reason is still a kickban, which is what the empty string says.
        #expect(
            actions("/kickban bob")
                == [.ban(channel: "#swift", subject: "bob", isSet: true, kickReason: "")]
        )
        #expect(
            actions("/ban #other *!*@evil.example")
                == [
                    .ban(
                        channel: "#other",
                        subject: "*!*@evil.example",
                        isSet: true,
                        kickReason: nil
                    )
                ]
        )
        #expect(try error("/ban", in: nil).contains("/ban"))
    }

    @Test("invite defaults to the window's channel")
    func invite() throws {
        #expect(wire("/invite bob") == ["INVITE bob #swift"])
        #expect(wire("/invite bob #other") == ["INVITE bob #other"])
        #expect(try error("/invite").contains("/invite"))
    }

    /// `/ignore` belongs with the ignore *list*, which is a later prompt. Left out of the
    /// table entirely rather than half-built — so it passes through to the server, which
    /// answers with an error the user can see, rather than silently doing nothing.
    @Test("ignore is deliberately not in the table yet")
    func ignoreIsDeferred() {
        #expect(!CommandParser.knownCommands.contains("ignore"))
    }
}
