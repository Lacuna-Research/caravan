import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// Private messages in their own windows.
///
/// The assertions are about `ConnectionViewModel.queries`, the selection and what is in
/// each buffer's scrollback — the things the tree and the detail pane actually read.
@MainActor
@Suite("Query windows")
struct QueryWindowTests {
    @MainActor
    private final class Harness {
        let server: ScriptedIRCServer
        let model: AppModel
        private var readers: [ObjectIdentifier: NSTextView] = [:]

        init(server: ScriptedIRCServer, model: AppModel) {
            self.server = server
            self.model = model
        }

        var connection: ConnectionViewModel { model.activeConnection! }

        func text(of log: MessageLogController) -> String {
            let key = ObjectIdentifier(log)
            if readers[key] == nil {
                readers[key] = log.displayView().documentView as? NSTextView
            }
            log.flush()
            return readers[key]?.string ?? ""
        }

        func query(_ nick: String) -> QueryBuffer? {
            connection.query(named: IRCNick(nick, mapping: .ascii))
        }

        func shutDown() async {
            await model.disconnect()
            await server.stop()
        }
    }

    /// `echoMessage` scripts a server that offers and acknowledges the capability, so the
    /// same behaviour can be checked with the server echoing and with it not.
    private func harness(echoMessage: Bool = false) async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        if echoMessage {
            await server.scriptCapabilityNegotiation(nick: "alice", offering: ["echo-message"])
        } else {
            await server.scriptWelcome(nick: "alice")
        }

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

    private func nick(_ raw: String) -> IRCNick { IRCNick(raw, mapping: .ascii) }

    // MARK: - Opening

    /// The whole feature in one assertion: a PM no longer lands in the status window.
    @Test("an incoming private message opens a window of its own")
    func incomingMessageOpensAQuery() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h PRIVMSG alice :are you around?")

        #expect(await waitUntil { harness.connection.queries.count == 1 })
        let buffer = try #require(harness.query("bob"))
        #expect(buffer.nick == nick("bob"))
        #expect(await waitUntil { harness.text(of: buffer.log).contains("<bob> are you around?") })
        // And not in the status window, which is where it used to go.
        #expect(!harness.text(of: harness.connection.log).contains("are you around?"))

        await harness.shutDown()
    }

    /// A person who capitalises their nick differently from one line to the next is one
    /// person, and one window.
    @Test("case does not open a second window for the same person")
    func caseFoldsToOneWindow() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h PRIVMSG alice :first")
        #expect(await waitUntil { harness.connection.queries.count == 1 })
        await harness.server.send(":BoB!u@h PRIVMSG alice :second")

        #expect(
            await waitUntil { harness.text(of: harness.query("bob")!.log).contains("second") }
        )
        #expect(harness.connection.queries.count == 1)

        await harness.shutDown()
    }

    /// **A notice never opens a window.** Services, the bouncer and half the network send
    /// them, and a window per sender is how the status window came to exist.
    @Test("a notice lands in the status window, and opens nothing")
    func noticesDoNotOpenWindows() async throws {
        let harness = try await harness()
        await harness.server.send(":NickServ!s@services. NOTICE alice :This nick is registered")
        await harness.server.send(":irc.example.org NOTICE alice :*** Looking up your hostname")

        #expect(
            await waitUntil {
                harness.text(of: harness.connection.log).contains("This nick is registered")
            }
        )
        #expect(harness.connection.queries.isEmpty)

        await harness.shutDown()
    }

    /// Once a conversation *is* open, a notice from that person belongs in it — NickServ
    /// answering in the NickServ window is what you want.
    @Test("a notice from someone you are talking to lands in their window")
    func noticesJoinAnOpenConversation() async throws {
        let harness = try await harness()
        await harness.server.send(":NickServ!s@services. PRIVMSG alice :hello")
        #expect(await waitUntil { harness.connection.queries.count == 1 })

        await harness.server.send(":NickServ!s@services. NOTICE alice :now by notice")
        let buffer = try #require(harness.query("NickServ"))
        #expect(await waitUntil { harness.text(of: buffer.log).contains("now by notice") })
        #expect(!harness.text(of: harness.connection.log).contains("now by notice"))

        await harness.shutDown()
    }

    // MARK: - /query

    /// The difference from `/msg`: the message is optional, and nothing goes on the wire.
    @Test("/query opens a window and selects it, saying nothing")
    func queryCommandOpensAWindow() async throws {
        let harness = try await harness()
        await harness.model.submit("/query bob", from: nil)

        #expect(harness.connection.queries.count == 1)
        #expect(
            harness.model.selection == .query(connection: harness.connection.id, nick: nick("bob"))
        )
        #expect(harness.model.selectedQuery?.nick == nick("bob"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !harness.server.receivedLines().contains { $0.hasPrefix("PRIVMSG bob") })

        await harness.shutDown()
    }

    @Test("/query with a message opens the window and says it there")
    func queryCommandWithAMessage() async throws {
        let harness = try await harness()
        await harness.model.submit("/query bob hi there", from: nil)

        let buffer = try #require(harness.query("bob"))
        #expect(await waitUntil { harness.text(of: buffer.log).contains("<alice> hi there") })
        // Typed into bob's own window, so it is not marked as leaving one.
        #expect(!harness.text(of: buffer.log).contains("-> *bob*"))
        #expect(
            await waitUntil {
                await harness.server.receivedLines().contains("PRIVMSG bob :hi there")
            }
        )

        await harness.shutDown()
    }

    /// `/query #swift` is somebody reaching for `/join`, and a private-looking window
    /// that sends `PRIVMSG #swift` would be a trap.
    @Test("/query refuses a channel")
    func queryRefusesAChannel() async throws {
        let harness = try await harness()
        await harness.model.submit("/query #swift", from: nil)

        #expect(harness.connection.queries.isEmpty)
        #expect(
            await waitUntil { harness.text(of: harness.connection.log).contains("/join") }
        )

        await harness.shutDown()
    }

    // MARK: - Where our own words go

    /// The carry-forward from stage 1 prompt 11, now that there is a window to answer it:
    /// `/msg bob hi` typed in `#swift` still reads `-> *bob* hi` *there*, and reads as an
    /// ordinary line of the conversation in bob's window.
    @Test("a message sent from elsewhere is marked there and plain in the conversation")
    func echoGoesBothPlaces() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let channel = try #require(harness.connection.channels.first)

        await harness.model.submit(
            "/msg bob a word in private",
            from: .channel(IRCChannelName("#swift", mapping: .ascii))
        )

        #expect(
            await waitUntil { harness.text(of: channel.log).contains("-> *bob* a word in private") }
        )
        let buffer = try #require(harness.query("bob"))
        #expect(harness.text(of: buffer.log).contains("<alice> a word in private"))

        await harness.shutDown()
    }

    /// **The same behaviour whether or not the server echoes for us.** Under
    /// `echo-message` the server's copy of what we sent comes back through the inbound
    /// path; without it the local echo does the same job. A `/msg` that opened a window on
    /// one network and not on another would be the capability leaking into behaviour.
    @Test("echo-message changes where the line comes from, not where it lands")
    func echoMessageLandsInTheConversation() async throws {
        let harness = try await harness(echoMessage: true)
        #expect(harness.connection.capabilities.isEnabled(.echoMessage))

        await harness.model.submit("/msg bob hi", from: nil)
        // The server has not echoed anything, but the window exists and is selected-able.
        #expect(await waitUntil { harness.connection.queries.count == 1 })

        // Now the server's copy arrives, named for the *target* rather than the sender.
        await harness.server.send(":alice!u@h PRIVMSG bob :hi")
        let buffer = try #require(harness.query("bob"))
        #expect(await waitUntil { harness.text(of: buffer.log).contains("<alice> hi") })
        #expect(harness.connection.queries.count == 1)

        await harness.shutDown()
    }

    // MARK: - The header band

    /// §14: a query's band shows conversational context rather than a topic.
    @Test("the band summarises the conversation, and says so when there is none")
    func headerBandContext() async throws {
        let harness = try await harness()
        await harness.model.submit("/query bob", from: nil)
        let buffer = try #require(harness.query("bob"))

        #expect(buffer.contextSummary == nil)
        #expect(buffer.contextPlaceholder.contains("bob"))

        await harness.server.send(":bob!u@h PRIVMSG alice :are you around?")
        #expect(await waitUntil { buffer.conversation.messageCount == 1 })
        #expect(try #require(buffer.contextSummary).contains("1 message"))
        #expect(try #require(buffer.contextSummary).contains("bob: are you around?"))

        await harness.model.submit("/msg bob yes", from: .nick(nick("bob")))
        await harness.server.send(":bob!u@h PRIVMSG alice :\u{01}ACTION waves\u{01}")
        #expect(await waitUntil { buffer.conversation.messageCount == 3 })

        let summary = try #require(buffer.contextSummary)
        // Both ends, and both directions: a band showing only what the other person said
        // would report the wrong last message every time you had the last word.
        #expect(summary.contains("3 messages"))
        #expect(summary.contains("First — bob: are you around?"))
        #expect(summary.contains("Latest — * bob waves"))

        // **Latest on the second line.** The band collapses to two, and the live run
        // showed the useful half — what was said most recently — hidden behind the
        // chevron when `First` came first.
        let lines = summary.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("Latest — "))
        #expect(lines[2].hasPrefix("First — "))

        await harness.shutDown()
    }

    /// The band is plain `Text`, so a `^C` reaching it renders as a control picture.
    @Test("formatting codes are stripped out of the band")
    func headerBandStripsFormatting() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h PRIVMSG alice :\u{03}04red\u{03} and \u{02}bold\u{02}")
        #expect(await waitUntil { harness.query("bob")?.conversation.messageCount == 1 })

        let summary = try #require(harness.query("bob")?.contextSummary)
        #expect(summary.contains("bob: red and bold"))
        #expect(!summary.contains("\u{03}"))
        #expect(!summary.contains("\u{02}"))

        await harness.shutDown()
    }

    // MARK: - Closing

    /// ⌘W on a conversation closes a window. On a channel it parts. The two are not the
    /// same act, and the title says which.
    @Test("closing a conversation sends nothing and takes the row away")
    func closingSendsNothing() async throws {
        let harness = try await harness()
        await harness.model.submit("/query bob", from: nil)
        #expect(harness.model.closeBufferTitle == "Close Conversation")

        await harness.model.closeSelectedBuffer()
        #expect(harness.connection.queries.isEmpty)
        #expect(harness.model.selection == .status(harness.connection.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !harness.server.receivedLines().contains { $0.hasPrefix("PART") })

        await harness.shutDown()
    }

    // MARK: - CTCP in the UI

    /// A `VERSION` request used to render as control characters in whatever window it
    /// arrived in. It is now a line that says what happened, and it opens no window —
    /// fifty strangers probing must not conjure fifty rows.
    @Test("a CTCP request reads as one and opens nothing")
    func ctcpRequestRendering() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h PRIVMSG alice :\u{01}VERSION\u{01}")

        #expect(
            await waitUntil {
                harness.text(of: harness.connection.log).contains("CTCP VERSION from bob")
            }
        )
        #expect(harness.connection.queries.isEmpty)
        #expect(!harness.text(of: harness.connection.log).contains("\u{01}"))

        await harness.shutDown()
    }

    @Test("a CTCP reply reads as an answer")
    func ctcpReplyRendering() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h NOTICE alice :\u{01}VERSION mIRC v7.75\u{01}")

        #expect(
            await waitUntil {
                harness.text(of: harness.connection.log)
                    .contains("CTCP reply from bob: VERSION mIRC v7.75")
            }
        )

        await harness.shutDown()
    }

    /// Found by the live run against Libera, which negotiates `echo-message`: our own
    /// auto-reply came back and rendered as `CTCP reply from caravan-q5` — our own nick,
    /// reading as though a stranger had answered a question we never asked.
    @Test("our own auto-reply reads as ours, not as somebody answering us")
    func ownCtcpReplyRendering() async throws {
        let harness = try await harness(echoMessage: true)
        #expect(harness.connection.capabilities.isEnabled(.echoMessage))

        await harness.server.send(":bob!u@h PRIVMSG alice :\u{01}VERSION\u{01}")
        // The server's copy of the NOTICE we just sent: we are the sender, bob the target.
        await harness.server.send(":alice!u@h NOTICE bob :\u{01}VERSION Caravan test\u{01}")

        #expect(
            await waitUntil {
                harness.text(of: harness.connection.log)
                    .contains("CTCP reply to bob: VERSION Caravan test")
            }
        )
        #expect(!harness.text(of: harness.connection.log).contains("CTCP reply from alice"))

        await harness.shutDown()
    }

    /// A conversation already open is a better home for a probe than the status window.
    @Test("a CTCP from someone you are talking to lands in their window")
    func ctcpJoinsAnOpenConversation() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h PRIVMSG alice :hi")
        #expect(await waitUntil { harness.connection.queries.count == 1 })

        await harness.server.send(":bob!u@h PRIVMSG alice :\u{01}PING 42\u{01}")
        let buffer = try #require(harness.query("bob"))
        #expect(await waitUntil { harness.text(of: buffer.log).contains("CTCP PING 42 from bob") })

        await harness.shutDown()
    }

    /// A CTCP is not a line of conversation, so it must not move the header band's idea of
    /// what was last said.
    @Test("a CTCP is not part of the conversation")
    func ctcpIsNotConversation() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h PRIVMSG alice :hi")
        #expect(await waitUntil { harness.connection.queries.count == 1 })
        await harness.server.send(":bob!u@h PRIVMSG alice :\u{01}PING 42\u{01}")

        let buffer = try #require(harness.query("bob"))
        #expect(await waitUntil { harness.text(of: buffer.log).contains("CTCP PING") })
        #expect(buffer.conversation.messageCount == 1)
        #expect(buffer.contextSummary?.contains("bob: hi") == true)

        await harness.shutDown()
    }

    // MARK: - The tree

    /// §12: one flat list per network, channels first, then conversations. Keeps channel
    /// positions stable as transient PMs come and go.
    @Test("queries sort after channels, in their own arrival order")
    func treeOrdering() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h PRIVMSG alice :first")
        #expect(await waitUntil { harness.connection.queries.count == 1 })
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        await harness.server.send(":carol!u@h PRIVMSG alice :second")
        #expect(await waitUntil { harness.connection.queries.count == 2 })

        // The channel arrived *after* the first query and still sorts before it.
        #expect(harness.connection.channels.map(\.name.raw) == ["#swift"])
        #expect(harness.connection.queries.map(\.nick.raw) == ["bob", "carol"])

        await harness.shutDown()
    }

    /// A disconnected network keeps its buffers, greyed (§17) — including its
    /// conversations, which have no membership to lose in the first place.
    @Test("a conversation survives a disconnect")
    func survivesDisconnect() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h PRIVMSG alice :hi")
        #expect(await waitUntil { harness.connection.queries.count == 1 })

        await harness.model.disconnect()
        #expect(await waitUntil { harness.connection.isConnected == false })
        #expect(harness.connection.queries.count == 1)
        #expect(harness.text(of: harness.query("bob")!.log).contains("<bob> hi"))

        await harness.shutDown()
    }
}
