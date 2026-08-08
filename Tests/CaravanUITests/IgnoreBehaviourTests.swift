import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// What an ignore does to an arriving line, end to end.
///
/// Driven through a scripted server rather than by calling the matcher, because the whole
/// value of the feature is that *five* consumers stop seeing the line at once and only the
/// real path proves all five.
@MainActor
@Suite("Ignoring somebody")
struct IgnoreBehaviourTests {
    @MainActor
    private struct Reader {
        let log: MessageLogController
        let textView: NSTextView

        var text: String {
            log.flush()
            return textView.string
        }

        func count(of needle: String) -> Int {
            text.components(separatedBy: needle).count - 1
        }
    }

    @MainActor
    private struct Harness {
        let server: ScriptedIRCServer
        let connection: ConnectionViewModel
        let ignores: IgnoreList
        let catcher: URLCatcher
        let chatLog: ChatLog

        @discardableResult
        func attach(_ log: MessageLogController) -> Reader {
            let textView = MessageLogView.makeTextView(usesTextKit2: false)
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            scrollView.documentView = textView
            log.attach(textView: textView, scrollView: scrollView)
            scrollView.layoutSubtreeIfNeeded()
            return Reader(log: log, textView: textView)
        }

        func logLines(_ buffer: String) -> [String] {
            chatLog.tail(1000, network: connection.networkKey, buffer: buffer)
        }

        func shutDown() async {
            await connection.disconnect()
            await server.stop()
            chatLog.close()
        }
    }

    private func harness() async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let config = temporaryConfig()
        let connection = ConnectionViewModel(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: port,
                tls: .disabled,
                nick: "alice",
                realName: "Alice Example"
            ),
            trace: TraceBuffer(capacity: 512),
            settings: ChatSettings(config: config)
        )
        let ignores = IgnoreList(config: config)
        let catcher = URLCatcher()
        let chatLog = temporaryChatLog()
        connection.ignores = ignores
        connection.urlCatcher = catcher
        connection.chatLog = chatLog
        let harness = Harness(
            server: server,
            connection: connection,
            ignores: ignores,
            catcher: catcher,
            chatLog: chatLog
        )
        await connection.connect()
        #expect(await waitUntil { connection.isConnected })
        return harness
    }

    /// Joins `#swift`, gets bob in, and hands back the buffer and a reader for it.
    private func channel(_ harness: Harness) async throws -> (ChannelBuffer, Reader) {
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)
        let reader = harness.attach(buffer.log)
        await harness.server.send(":bob!~bob@home.example JOIN #swift")
        #expect(await waitUntil { buffer.memberCount == 2 })
        return (buffer, reader)
    }

    // MARK: - The five seams

    /// The whole point, in one test: a line the user was never shown must not reach any of
    /// the four other consumers either.
    @Test("an ignored line reaches none of the five consumers")
    func suppressionIsTotal() async throws {
        let harness = try await harness()
        let (buffer, reader) = try await channel(harness)
        harness.ignores.add(IgnoreEntry(mask: "bob!*@*"))
        buffer.activity = .none

        await harness.server.send(
            ":bob!~bob@home.example PRIVMSG #swift :look at https://example.com/x"
        )
        // A barrier in another buffer, so waiting for it does not itself touch the one
        // being asserted on.
        await harness.server.send(":irc.example.org NOTICE alice :barrier")
        let status = harness.attach(harness.connection.log)
        #expect(await waitUntil { status.text.contains("barrier") })

        #expect(!reader.text.contains("example.com"))
        #expect(buffer.activity == .none)
        #expect(harness.catcher.entries.isEmpty)
        #expect(!harness.logLines("#swift").contains { $0.contains("example.com") })
        await harness.shutDown()
    }

    /// **The invariant the whole feature rests on.** An ignore hides lines; it never
    /// changes state.
    @Test("an ignored person is still in the channel, and still leaves it")
    func stateIsNeverSuppressed() async throws {
        let harness = try await harness()
        let (buffer, reader) = try await channel(harness)
        harness.ignores.add(IgnoreEntry(mask: "bob!*@*"))

        await harness.server.send(":carol!c@h JOIN #swift")
        #expect(await waitUntil { buffer.memberCount == 3 })
        // Bob is in the nick list even though his own join line was hidden, and carol's
        // was not hidden at all.
        #expect(buffer.channel.contains(IRCNick("bob", mapping: .ascii)))
        #expect(reader.text.contains("Joins: carol"))

        await harness.server.send(":bob!~bob@home.example QUIT :bye")
        #expect(await waitUntil { buffer.memberCount == 2 })
        #expect(!buffer.channel.contains(IRCNick("bob", mapping: .ascii)))
        // The roster moved; the line never appeared.
        #expect(!reader.text.contains("Quits: bob"))
        await harness.shutDown()
    }

    /// An ignore is a display filter, not a censor of diagnostics. Somebody working out why
    /// they cannot see a person has to be able to see them.
    @Test("the wire trace still shows what was suppressed")
    func rawTrafficIsNeverFiltered() async throws {
        let harness = try await harness()
        let (_, _) = try await channel(harness)
        harness.connection.settings.showsRawTraffic = true
        harness.ignores.add(IgnoreEntry(mask: "bob!*@*"))
        let status = harness.attach(harness.connection.log)

        await harness.server.send(":bob!~bob@home.example PRIVMSG #swift :invisible")
        #expect(await waitUntil { status.text.contains("invisible") })
        // Present in the raw view, and marked as inbound rather than rendered as chat.
        #expect(status.text.contains("<< :bob!~bob@home.example PRIVMSG"))
        await harness.shutDown()
    }

    // MARK: - Levels

    @Test("a level ignores what it names and nothing else")
    func levelsAreHonoured() async throws {
        let harness = try await harness()
        let (_, reader) = try await channel(harness)
        harness.ignores.add(IgnoreEntry(mask: "bob!*@*", levels: .channelMessages))

        await harness.server.send(":bob!~bob@home.example PRIVMSG #swift :hidden")
        await harness.server.send(":bob!~bob@home.example NOTICE #swift :still here")
        #expect(await waitUntil { reader.text.contains("still here") })
        #expect(!reader.text.contains("hidden"))
        await harness.shutDown()
    }

    @Test("movement hides the joining and parting without touching what is said")
    func movementLevel() async throws {
        let harness = try await harness()
        let (buffer, reader) = try await channel(harness)
        harness.ignores.add(IgnoreEntry(mask: "flap!*@*", levels: .movement))

        await harness.server.send(":flap!f@h JOIN #swift")
        #expect(await waitUntil { buffer.memberCount == 3 })
        await harness.server.send(":flap!f@h PRIVMSG #swift :still worth reading")
        #expect(await waitUntil { reader.text.contains("still worth reading") })
        #expect(!reader.text.contains("Joins: flap"))
        await harness.shutDown()
    }

    /// `k` is the one level that keeps the line.
    @Test("control codes are stripped rather than the line being hidden")
    func controlCodeLevel() async throws {
        let harness = try await harness()
        let (_, reader) = try await channel(harness)
        harness.ignores.add(IgnoreEntry(mask: "bob!*@*", levels: .controlCodes))

        await harness.server.send(
            ":bob!~bob@home.example PRIVMSG #swift :\u{03}04loud\u{03} but readable"
        )
        #expect(await waitUntil { reader.text.contains("loud but readable") })
        // The renderer strips codes from the buffer anyway; what this proves is that the
        // line survived at all, which is the difference between `k` and every other level.
        #expect(reader.count(of: "loud but readable") == 1)
        await harness.shutDown()
    }

    // MARK: - The edges

    /// A mask broad enough to catch your own `nick!user@host` would silently eat your own
    /// echo, which is a client appearing to drop what you type.
    @Test("you cannot ignore yourself, even with a mask that matches you")
    func neverIgnoreYourself() async throws {
        let harness = try await harness()
        let (_, reader) = try await channel(harness)
        harness.ignores.add(IgnoreEntry(mask: "*!*@*"))

        await harness.connection.send(
            IRCMessage(verb: "PRIVMSG", parameters: ["#swift", "my own words"]),
            from: .channel(IRCChannelName("#swift", mapping: .ascii))
        )
        #expect(await waitUntil { reader.text.contains("my own words") })
        // And the broad mask really is in force for everybody else.
        await harness.server.send(":bob!~bob@home.example PRIVMSG #swift :not shown")
        await harness.server.send(":irc.example.org NOTICE alice :barrier")
        let status = harness.attach(harness.connection.log)
        #expect(await waitUntil { status.text.contains("barrier") })
        #expect(!reader.text.contains("not shown"))
        await harness.shutDown()
    }

    /// Being thrown out of a channel is news about *you*. A client that hid it because you
    /// had ignored the operator would leave you wondering why the window went quiet.
    @Test("a kick is never ignorable")
    func kicksAreAlwaysShown() async throws {
        let harness = try await harness()
        let (_, reader) = try await channel(harness)
        harness.ignores.add(IgnoreEntry(mask: "*!*@*"))

        await harness.server.send(":bob!~bob@home.example KICK #swift alice :out")
        #expect(await waitUntil { reader.text.contains("kicked") })
        await harness.shutDown()
    }

    @Test("an ignore applies from the moment it is set, never backwards")
    func neverRetroactive() async throws {
        let harness = try await harness()
        let (_, reader) = try await channel(harness)

        await harness.server.send(":bob!~bob@home.example PRIVMSG #swift :said before")
        #expect(await waitUntil { reader.text.contains("said before") })

        harness.ignores.add(IgnoreEntry(mask: "bob!*@*"))
        await harness.server.send(":bob!~bob@home.example PRIVMSG #swift :said after")
        await harness.server.send(":irc.example.org NOTICE alice :barrier")
        let status = harness.attach(harness.connection.log)
        #expect(await waitUntil { status.text.contains("barrier") })

        // What was already on screen stays on screen, exactly as the raw-traffic toggle
        // does not reach back either.
        #expect(reader.text.contains("said before"))
        #expect(!reader.text.contains("said after"))
        #expect(harness.logLines("#swift").contains { $0.contains("said before") })
        await harness.shutDown()
    }

    /// `/ignore` typed, rather than the list poked directly — the path a user takes.
    @Test("the command adds, lists and removes, and says what it did")
    func throughTheCommand() async throws {
        let harness = try await harness()
        let model = temporaryModel()
        let ignores = model.ignores

        #expect(
            model.applyIgnore(subject: "bob", levels: .all, duration: nil, isRemoval: false)
                == "Ignoring bob!*@* — everything"
        )
        #expect(ignores.entries.map(\.mask) == ["bob!*@*"])

        let corrected = model.applyIgnore(
            subject: "bob",
            levels: [.privateMessages, .notices],
            duration: nil,
            isRemoval: false
        )
        #expect(corrected == "Ignoring bob!*@* — private messages and notices")
        #expect(ignores.entries.count == 1, "a correction, not a second entry")

        #expect(
            model.applyIgnore(subject: "carol", levels: .all, duration: 600, isRemoval: false)
                == "Ignoring carol!*@* for 10 minutes — everything"
        )

        let listing = model.applyIgnore(
            subject: nil,
            levels: .all,
            duration: nil,
            isRemoval: false
        )
        #expect(listing.contains("bob!*@* — private messages and notices"))
        #expect(listing.contains("carol!*@*"))

        #expect(
            model.applyIgnore(subject: "bob", levels: .all, duration: nil, isRemoval: true)
                == "No longer ignoring bob!*@*"
        )
        #expect(
            model.applyIgnore(subject: "bob", levels: .all, duration: nil, isRemoval: true)
                == "bob!*@* was not being ignored"
        )
        await harness.shutDown()
    }

    @Test("a duration is spelled the way it was meant")
    func durations() {
        #expect(AppModel.spelled(seconds: 1) == "1 second")
        #expect(AppModel.spelled(seconds: 30) == "30 seconds")
        #expect(AppModel.spelled(seconds: 60) == "1 minute")
        #expect(AppModel.spelled(seconds: 600) == "10 minutes")
        #expect(AppModel.spelled(seconds: 7200) == "2 hours")
    }
}
