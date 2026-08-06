import IRCProtocol
import Testing

@testable import IRCSession

/// The verbs and numerics the IRCv3 capabilities introduce.
///
/// Kept apart from `EventTranslatorTests` because they are one prompt's worth of table and
/// they share a fixture — everything here is a line that only appears once a capability is
/// negotiated.
@Suite("IRCv3 events")
struct IRCv3EventTests {
    private var capabilities: ServerCapabilities {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: ["CASEMAPPING=ascii", "CHANTYPES=#", "PREFIX=(ov)@+"])
        return capabilities
    }

    private func events(_ line: String) throws -> [IRCEvent] {
        let message = try #require(IRCMessage(line: line))
        return EventTranslator.events(for: message, capabilities: capabilities)
    }

    /// Everything past `.raw`, which every line produces and none of these tests are about.
    private func specific(_ line: String) throws -> [IRCEvent] {
        Array(try events(line).dropFirst())
    }

    private func channel(_ name: String) -> IRCChannelName {
        IRCChannelName(name, mapping: .ascii)
    }

    private func user(_ nick: String) -> IRCSource {
        IRCSource(prefix: "\(nick)!u@example.org")
    }

    // MARK: - extended-join

    @Test("extended-join carries the account and the real name")
    func extendedJoin() throws {
        #expect(
            try specific(":bob!u@example.org JOIN #swift alice :Bob Example") == [
                .joined(
                    channel: channel("#swift"),
                    who: user("bob"),
                    account: "alice",
                    realName: "Bob Example"
                )
            ]
        )
    }

    /// `*` is the wire's "logged in to nothing", and it is not a nick anyone can hold.
    @Test("a star account is no account")
    func extendedJoinWithoutAccount() throws {
        #expect(
            try specific(":bob!u@example.org JOIN #swift * :Bob Example") == [
                .joined(
                    channel: channel("#swift"),
                    who: user("bob"),
                    account: nil,
                    realName: "Bob Example"
                )
            ]
        )
    }

    @Test("a plain JOIN still parses, with neither")
    func plainJoin() throws {
        #expect(
            try specific(":bob!u@example.org JOIN #swift") == [
                .joined(channel: channel("#swift"), who: user("bob"), account: nil, realName: nil)
            ]
        )
    }

    // MARK: - away-notify, account-notify, chghost, setname

    @Test("AWAY with a reason is away, and without one is back")
    func away() throws {
        #expect(
            try specific(":bob!u@example.org AWAY :making tea") == [
                .awayChanged(who: user("bob"), message: "making tea")
            ]
        )
        #expect(
            try specific(":bob!u@example.org AWAY") == [
                .awayChanged(who: user("bob"), message: nil)
            ]
        )
        // An empty reason is a return too: there is no such thing as being away for "".
        #expect(
            try specific(":bob!u@example.org AWAY :") == [
                .awayChanged(who: user("bob"), message: nil)
            ]
        )
    }

    @Test("ACCOUNT logs in and out")
    func account() throws {
        #expect(
            try specific(":bob!u@example.org ACCOUNT robert") == [
                .accountChanged(who: user("bob"), account: "robert")
            ]
        )
        #expect(
            try specific(":bob!u@example.org ACCOUNT *") == [
                .accountChanged(who: user("bob"), account: nil)
            ]
        )
    }

    @Test("CHGHOST carries the new user and host")
    func chghost() throws {
        #expect(
            try specific(":bob!u@example.org CHGHOST bobby cloak.example.org") == [
                .hostChanged(who: user("bob"), user: "bobby", host: "cloak.example.org")
            ]
        )
    }

    @Test("SETNAME carries the new real name")
    func setname() throws {
        #expect(
            try specific(":bob!u@example.org SETNAME :Robert Example") == [
                .realNameChanged(who: user("bob"), realName: "Robert Example")
            ]
        )
    }

    // MARK: - invite-notify

    @Test("an INVITE names who, whom and where")
    func invite() throws {
        #expect(
            try specific(":bob!u@example.org INVITE alice #swift") == [
                .invited(by: user("bob"), nick: "alice", channel: channel("#swift"))
            ]
        )
    }

    /// 341 answers our own `/invite`, and has no source worth attributing it to.
    @Test("341 is the same event with nobody to attribute it to")
    func inviteConfirmation() throws {
        #expect(
            try specific(":irc.example.org 341 alice carol #swift") == [
                .invited(by: nil, nick: "carol", channel: channel("#swift"))
            ]
        )
    }

    // MARK: - standard-replies

    @Test("FAIL, WARN and NOTE keep their severity")
    func standardReplies() throws {
        #expect(
            try specific("FAIL JOIN CHANNEL_FULL #swift :Channel is full") == [
                .standardReply(
                    StandardReply(
                        severity: .fail,
                        command: "JOIN",
                        code: "CHANNEL_FULL",
                        context: ["#swift"],
                        text: "Channel is full"
                    )
                )
            ]
        )
        #expect(
            try specific("WARN * ACCOUNT_NAME_MUST_BE_NICK :Renamed") == [
                .standardReply(
                    StandardReply(
                        severity: .warn,
                        command: "*",
                        code: "ACCOUNT_NAME_MUST_BE_NICK",
                        text: "Renamed"
                    )
                )
            ]
        )
        guard case .standardReply(let note) = try #require(try specific("NOTE * X :hello").first)
        else {
            Issue.record("expected a standard reply")
            return
        }
        #expect(note.severity == .note)
    }

    /// Too short to be a standard reply. It still reaches the status window as `.raw`,
    /// which is the guarantee that matters, rather than being dropped into a wrong shape.
    @Test("a truncated standard reply falls through rather than being invented")
    func truncatedStandardReply() throws {
        #expect(try specific("FAIL JOIN").isEmpty)
    }

    // MARK: - batch

    @Test("BATCH opens and closes, carrying its reference and type")
    func batch() throws {
        #expect(
            try specific(":s BATCH +abc chathistory #swift") == [
                .batchStarted(reference: "abc", type: "chathistory", parameters: ["#swift"])
            ]
        )
        #expect(try specific(":s BATCH -abc") == [.batchEnded(reference: "abc")])
    }

    // MARK: - server-time and message tags

    /// The tags ride on the event because only the consumer can use them: this module has
    /// no clock and no date formatter, and `server-time` is a question about rendering.
    @Test("a message carries its tags, so server-time reaches the renderer")
    func messageTags() throws {
        guard
            case .message(_, _, _, _, _, let tags) = try #require(
                try specific("@time=2011-10-19T16:40:51.620Z;msgid=x :bob!u@h PRIVMSG #swift :hi")
                    .first
            )
        else {
            Issue.record("expected a message event")
            return
        }
        #expect(tags.value(for: "time") == "2011-10-19T16:40:51.620Z")
        #expect(tags.value(for: "msgid") == "x")
    }

    // MARK: - SASL numerics

    @Test("900 is the account we ended up logged in as")
    func loggedIn() throws {
        #expect(
            try specific(":s 900 alice alice!u@h robert :You are now logged in as robert") == [
                .authenticated(account: "robert")
            ]
        )
    }

    /// The session drives `CAP` and `AUTHENTICATE`; the translator deliberately says
    /// nothing about them beyond `.raw`, which is where someone debugging a failed
    /// handshake goes looking.
    @Test("CAP and AUTHENTICATE produce only the raw line")
    func negotiationIsRawOnly() throws {
        #expect(try events(":s CAP * LS :sasl").count == 1)
        #expect(try events("AUTHENTICATE +").count == 1)
    }
}
