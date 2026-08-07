import CaravanTestSupport
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The four states, as a table. Pure, so being exhaustive costs nothing.
@Suite("Buffer activity")
struct BufferActivityTests {
    private func message(
        from nick: String,
        _ text: String,
        to target: Target = .channel(IRCChannelName("#swift", mapping: .ascii))
    ) -> IRCEvent {
        .message(
            target: target,
            sender: .user(nick: nick, user: "u", host: "h"),
            text: text,
            kind: .privmsg,
            isAction: false,
            tags: IRCTags()
        )
    }

    @Test("somebody talking is a message; somebody talking to you is a highlight")
    func speaking() {
        #expect(
            BufferActivity.caused(
                by: message(from: "bob", "morning all"),
                ownNick: "alice",
                isConversation: false
            ) == .message
        )
        #expect(
            BufferActivity.caused(
                by: message(from: "bob", "alice: have you seen this?"),
                ownNick: "alice",
                isConversation: false
            ) == .highlight
        )
    }

    /// §18 groups "highlights and private messages" as the two things worth notifying
    /// about. A query that could only reach `message` would wear the same colour as
    /// somebody chatting in `#swift`, and the whole reason a PM has its own window is that
    /// it is addressed to you.
    @Test("every message in a conversation is a highlight")
    func conversationsAreHighlights() {
        #expect(
            BufferActivity.caused(
                by: message(from: "bob", "hello", to: .nick(IRCNick("alice", mapping: .ascii))),
                ownNick: "alice",
                isConversation: true
            ) == .highlight
        )
    }

    /// Our own words coming back under `echo-message` are not news.
    @Test("our own message raises nothing")
    func ownMessage() {
        #expect(
            BufferActivity.caused(
                by: message(from: "alice", "morning"),
                ownNick: "alice",
                isConversation: false
            ) == .none
        )
        // Including in a conversation, where the highlight rule would otherwise fire.
        #expect(
            BufferActivity.caused(
                by: message(from: "Alice", "hi", to: .nick(IRCNick("bob", mapping: .ascii))),
                ownNick: "alice",
                isConversation: true
            ) == .none
        )
    }

    @Test("a join, a mode or a numeric is activity, not a message")
    func events() {
        let joined = IRCEvent.joined(
            channel: IRCChannelName("#swift", mapping: .ascii),
            who: .user(nick: "bob", user: "u", host: "h"),
            account: nil,
            realName: nil
        )
        #expect(
            BufferActivity.caused(by: joined, ownNick: "alice", isConversation: false)
                == .activity
        )
        #expect(
            BufferActivity.caused(
                by: .numeric(code: 372, parameters: ["alice", "the motd"]),
                ownNick: "alice",
                isConversation: false
            ) == .activity
        )
    }

    /// These draw no line, so they cannot make a buffer unread. A buffer that lit up
    /// because a `NAMES` reply arrived would light up on every join in every channel.
    @Test("events that draw no line raise nothing")
    func silentEvents() {
        let channel = IRCChannelName("#swift", mapping: .ascii)
        for event in [
            IRCEvent.namesReply(channel: channel, names: ["alice"]),
            .endOfNames(channel: channel),
            .channelClosed(channel),
            .batchStarted(reference: "r", type: "chathistory", parameters: []),
            .batchEnded(reference: "r"),
            .bouncerNetworks([]),
        ] {
            #expect(
                BufferActivity.caused(by: event, ownNick: "alice", isConversation: false)
                    == .none,
                "\(event) should raise nothing"
            )
        }
    }

    /// Without the boundary rule a short nick highlights on almost every line, which
    /// trains people to ignore the state entirely.
    @Test(
        "a mention is a word, not a fragment",
        arguments: [
            ("bob: look at this", true),
            ("thanks, bob!", true),
            ("bob", true),
            ("(bob)", true),
            ("re: bob's patch", true),
            ("bobbins", false),
            ("bob2", false),
            ("robobob", false),
            ("nothing here", false),
        ]
    )
    func mentions(text: String, expected: Bool) {
        #expect(BufferActivity.mentions("bob", in: text) == expected)
    }

    @Test("matching is case-insensitive both ways")
    func mentionCase() {
        #expect(BufferActivity.mentions("Bob", in: "hey BOB"))
        #expect(BufferActivity.mentions("bob", in: "hey Bob"))
    }

    @Test("the states escalate, and only the top one badges")
    func ordering() {
        #expect(BufferActivity.none < .activity)
        #expect(BufferActivity.activity < .message)
        #expect(BufferActivity.message < .highlight)
        #expect(BufferActivity.allCases.filter(\.showsBadge) == [.highlight])
        #expect(BufferActivity.allCases.filter(\.isBold) == [.highlight])
    }
}

/// Activity as the app accumulates it: which buffer lights up, when it stops.
@MainActor
@Suite("Activity in the tree")
struct ActivityAccumulationTests {
    @MainActor
    private final class Harness {
        let server: ScriptedIRCServer
        let model: AppModel

        init(server: ScriptedIRCServer, model: AppModel) {
            self.server = server
            self.model = model
        }

        var connection: ConnectionViewModel { model.activeConnection! }

        func channel(_ name: String) -> ChannelBuffer? {
            connection.buffer(named: IRCChannelName(name, mapping: .ascii))
        }

        func shutDown() async {
            await model.disconnect()
            await server.stop()
        }
    }

    private func harness() async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let model = temporaryModel()
        let harness = Harness(server: server, model: model)
        await model.connect(
            using: ConnectionSettings(
                host: "127.0.0.1",
                port: port,
                useTLS: false,
                nick: "alice",
                realName: "Alice Example"
            )
        )
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        return harness
    }

    /// A buffer holds the *most urgent* thing since you last looked, so a join arriving
    /// after a highlight must not quietly downgrade it.
    @Test("activity rises and never falls until you look")
    func risesOnly() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.channel("#swift") != nil })
        let buffer = try #require(harness.channel("#swift"))
        // Look elsewhere, so #swift is not the selected buffer.
        harness.model.selection = .status(harness.connection.id)

        await harness.server.send(":bob!u@h PRIVMSG #swift :morning")
        #expect(await waitUntil { buffer.activity == .message })

        await harness.server.send(":bob!u@h PRIVMSG #swift :alice: look")
        #expect(await waitUntil { buffer.activity == .highlight })

        // A join afterwards is less urgent and leaves the state alone.
        await harness.server.send(":carol!u@h JOIN #swift")
        try await Task.sleep(for: .milliseconds(150))
        #expect(buffer.activity == .highlight)

        await harness.shutDown()
    }

    /// What makes the state mean "since you last looked" rather than "ever".
    @Test("the buffer you are looking at never accumulates one")
    func selectedBufferStaysQuiet() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.channel("#swift") != nil })
        let buffer = try #require(harness.channel("#swift"))
        harness.model.selection = .channel(
            connection: harness.connection.id,
            channel: buffer.name
        )

        await harness.server.send(":bob!u@h PRIVMSG #swift :alice: look at this")
        #expect(
            await waitUntil {
                harness.model.allBuffers.contains { $0.name == "#swift" }
            }
        )
        try await Task.sleep(for: .milliseconds(200))
        #expect(buffer.activity == .none)

        await harness.shutDown()
    }

    @Test("selecting a buffer clears it")
    func selectingClears() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.channel("#swift") != nil })
        let buffer = try #require(harness.channel("#swift"))
        harness.model.selection = .status(harness.connection.id)

        await harness.server.send(":bob!u@h PRIVMSG #swift :morning")
        #expect(await waitUntil { buffer.activity == .message })

        harness.model.selection = .channel(
            connection: harness.connection.id,
            channel: buffer.name
        )
        #expect(buffer.activity == .none)

        await harness.shutDown()
    }

    /// §9: a collapse that hides activity from you defeats the point of collapsing.
    @Test("a collapsed network rolls up the highest state among its children")
    func rollUp() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        await harness.server.send(":alice!u@h JOIN #vapor")
        #expect(await waitUntil { harness.connection.channels.count == 2 })
        harness.model.selection = .status(harness.connection.id)
        // Our own join is itself a line, and a line in a buffer you are not looking at is
        // activity — so the group is already awake before anyone speaks.
        #expect(harness.connection.rolledUpActivity == .activity)

        await harness.server.send(":bob!u@h PRIVMSG #swift :morning")
        #expect(await waitUntil { harness.connection.rolledUpActivity == .message })

        await harness.server.send(":bob!u@h PRIVMSG #vapor :alice: ping")
        #expect(await waitUntil { harness.connection.rolledUpActivity == .highlight })

        await harness.shutDown()
    }

    /// A PM opens a window *and* lights it up as a highlight, both in one step.
    @Test("a private message opens a conversation already highlighted")
    func privateMessage() async throws {
        let harness = try await harness()
        harness.model.selection = .status(harness.connection.id)
        await harness.server.send(":bob!u@h PRIVMSG alice :are you around?")

        #expect(await waitUntil { harness.connection.queries.count == 1 })
        let query = try #require(harness.connection.query(named: IRCNick("bob", mapping: .ascii)))
        #expect(await waitUntil { query.activity == .highlight })

        await harness.shutDown()
    }
}
