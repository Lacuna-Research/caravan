import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// Logging end to end: what reaches the file, what comes back out of it when a window
/// opens, and what happens when the server backfills the same period.
///
/// Driven through a scripted server rather than by calling `append` directly, because the
/// three things this feature has to get right — the file, the reload and the reconciliation
/// — meet in `ConnectionViewModel.append(_:)` and only the whole path proves they agree.
@MainActor
@Suite("Logging")
struct LoggingBehaviourTests {
    /// One buffer's rendered text, flushed on demand.
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
        let chatLog: ChatLog
        let settings: ChatSettings

        /// What this connection's logs are filed under, which depends on the port the test
        /// happened to get — so a test that seeds a log has to ask rather than assume.
        var network: String { connection.networkKey }

        @discardableResult
        func attach(_ log: MessageLogController) -> Reader {
            let textView = MessageLogView.makeTextView(usesTextKit2: false)
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            scrollView.documentView = textView
            log.attach(textView: textView, scrollView: scrollView)
            scrollView.layoutSubtreeIfNeeded()
            return Reader(log: log, textView: textView)
        }

        /// The file's contents, as lines. Flushed first: the writer holds the handle open.
        func logLines(_ buffer: String) -> [String] {
            chatLog.tail(1000, network: network, buffer: buffer)
        }

        func shutDown() async {
            await connection.disconnect()
            await server.stop()
            chatLog.close()
        }
    }

    /// - Parameters:
    ///   - capabilities: when non-empty, a full `CAP` negotiation offering these instead of
    ///     the bare welcome. `draft/chathistory` is the one the backfill tests need.
    private func harness(
        nick: String = "alice",
        chatLog: ChatLog? = nil,
        capabilities: [String] = []
    ) async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        if capabilities.isEmpty {
            await server.scriptWelcome(nick: nick)
        } else {
            await server.scriptCapabilityNegotiation(nick: nick, offering: capabilities)
        }
        // Its own config file: the suite must not read, or write, the settings of whoever
        // is running it — and a developer with logging turned off would otherwise see these
        // tests fail for a reason that is not a defect.
        let settings = ChatSettings(config: temporaryConfig())
        let connection = ConnectionViewModel(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: port,
                tls: .disabled,
                nick: nick,
                realName: "Alice Example",
                chatHistoryLimit: 25
            ),
            trace: TraceBuffer(capacity: 512),
            settings: settings
        )
        let log = chatLog ?? temporaryChatLog()
        connection.chatLog = log
        let harness = Harness(
            server: server,
            connection: connection,
            chatLog: log,
            settings: settings
        )
        await connection.connect()
        #expect(await waitUntil { connection.isConnected })
        return harness
    }

    /// A second connection to a *new* server, sharing the first one's log directory and
    /// network name — which is what a relaunch looks like from the log's point of view.
    private func relaunch(
        as network: String,
        chatLog: ChatLog,
        settings: ChatSettings
    ) async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let connection = ConnectionViewModel(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: port,
                tls: .disabled,
                nick: "alice",
                realName: "Alice Example"
            ),
            trace: TraceBuffer(capacity: 512),
            settings: settings
        )
        // The stable name is what a log file is keyed on, and it survives a reconnect to a
        // different address — which is the whole reason it is not `host:port`.
        connection.networkName = network
        connection.chatLog = chatLog
        let harness = Harness(
            server: server,
            connection: connection,
            chatLog: chatLog,
            settings: settings
        )
        await connection.connect()
        #expect(await waitUntil { connection.isConnected })
        return harness
    }

    // MARK: - Writing

    @Test("what is said in a channel is written down, in mIRC's sentence")
    func writesChannelLines() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        await harness.server.send(":bob!u@h PRIVMSG #swift :hello there")

        #expect(
            await waitUntil {
                harness.logLines("#swift").contains { $0.hasSuffix("<bob> hello there") }
            }
        )
        let line = try #require(
            harness.logLines("#swift").first { $0.contains("hello there") }
        )
        // The stamp is the canonical one, whatever the buffer is showing.
        #expect(LoggedLine(line).date != nil)
        #expect(line.hasPrefix("["))
        // The join was written too: an event line has no key but is still the record.
        #expect(harness.logLines("#swift").contains { $0.contains("*** Joins: alice") })
        await harness.shutDown()
    }

    @Test("our own words are written down, not only the ones we are told about")
    func writesOwnLines() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })

        await harness.connection.send(
            IRCMessage(verb: "PRIVMSG", parameters: ["#swift", "something I said"]),
            from: .channel(IRCChannelName("#swift", mapping: .ascii))
        )
        #expect(
            await waitUntil {
                harness.logLines("#swift").contains { $0.hasSuffix("<alice> something I said") }
            }
        )
        await harness.shutDown()
    }

    /// Off is off, and the status window is off by default.
    @Test("a buffer whose kind is not logged writes nothing")
    func honoursTheToggles() async throws {
        let harness = try await harness()
        harness.settings.logsChannels = false
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        await harness.server.send(":bob!u@h PRIVMSG #swift :hello there")
        let buffer = try #require(harness.connection.channels.first)
        let reader = harness.attach(buffer.log)
        #expect(await waitUntil { reader.text.contains("hello there") })

        // On screen, and nowhere else.
        #expect(harness.logLines("#swift").isEmpty)
        // The status window is not logged out of the box, so the MOTD and the numerics
        // that just went past it left no file behind either.
        #expect(harness.chatLog.networks().isEmpty)
        await harness.shutDown()
    }

    // MARK: - Reloading

    @Test("a window opens with the tail of its log above the live conversation")
    func reloadsOnOpen() async throws {
        let first = try await harness()
        await first.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { first.connection.channels.count == 1 })
        await first.server.send(":bob!u@h PRIVMSG #swift :said last time")
        #expect(
            await waitUntil {
                first.logLines("#swift").contains { $0.contains("said last time") }
            }
        )
        let network = first.network
        first.connection.networkName = network
        await first.shutDown()

        let second = try await relaunch(
            as: network,
            chatLog: first.chatLog,
            settings: first.settings
        )
        await second.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { second.connection.channels.count == 1 })
        let buffer = try #require(second.connection.channels.first)
        let reader = second.attach(buffer.log)

        #expect(await waitUntil { reader.text.contains("said last time") })
        // The whole logged line came back, stamp and all, rather than being re-rendered.
        #expect(reader.text.contains("<bob> said last time"))
        await second.shutDown()
    }

    @Test("a reload count of zero opens the window empty")
    func reloadCanBeTurnedOff() async throws {
        let first = try await harness()
        await first.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { first.connection.channels.count == 1 })
        await first.server.send(":bob!u@h PRIVMSG #swift :said last time")
        #expect(
            await waitUntil {
                first.logLines("#swift").contains { $0.contains("said last time") }
            }
        )
        let network = first.network
        await first.shutDown()

        first.settings.logReloadLines = 0
        let second = try await relaunch(
            as: network,
            chatLog: first.chatLog,
            settings: first.settings
        )
        await second.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { second.connection.channels.count == 1 })
        let buffer = try #require(second.connection.channels.first)
        let reader = second.attach(buffer.log)
        await second.server.send(":bob!u@h PRIVMSG #swift :said just now")
        #expect(await waitUntil { reader.text.contains("said just now") })

        // Still logging — the two settings are independent, which is the point of there
        // being two.
        #expect(!reader.text.contains("said last time"))
        #expect(second.logLines("#swift").contains { $0.contains("said just now") })
        await second.shutDown()
    }

    // MARK: - Reconciling with the server's own history

    /// The case the whole item exists for.
    @Test("a replay of what the log already holds is shown once")
    func deduplicatesAgainstTheLog() async throws {
        let chatLog = temporaryChatLog()
        let harness = try await harness(chatLog: chatLog)
        let network = harness.network

        // A line from an hour ago, in the log and about to be replayed by the server.
        let when = try #require(
            ChatLog.date(fromStamp: ChatLog.stamp(Date().addingTimeInterval(-3600)))
        )
        chatLog.write(
            "[\(ChatLog.stamp(when))] <bob> earlier line",
            network: network,
            buffer: "#swift"
        )
        chatLog.flush()

        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)
        let reader = harness.attach(buffer.log)
        #expect(await waitUntil { reader.text.contains("earlier line") })

        // The bouncer's copy of the same minute, carrying the server-time it was said at.
        await harness.server.send(
            "@time=\(Self.iso(when));msgid=abc :bob!u@h PRIVMSG #swift :earlier line"
        )
        // Something after it, so there is a point at which the replay has certainly landed.
        await harness.server.send(":bob!u@h PRIVMSG #swift :and something new")
        #expect(await waitUntil { reader.text.contains("and something new") })

        #expect(reader.count(of: "earlier line") == 1)
        // And it was not written to the file a second time either.
        #expect(harness.logLines("#swift").filter { $0.contains("earlier line") }.count == 1)
        await harness.shutDown()
    }

    /// De-duplication must not eat a real message.
    @Test("the same words said twice in one second stay two lines")
    func doesNotEatRepeats() async throws {
        let chatLog = temporaryChatLog()
        let harness = try await harness(chatLog: chatLog)
        let when = try #require(
            ChatLog.date(fromStamp: ChatLog.stamp(Date().addingTimeInterval(-3600)))
        )
        chatLog.write("[\(ChatLog.stamp(when))] <bob> lol", network: harness.network, buffer: "#x")
        chatLog.flush()

        await harness.server.send(":alice!u@h JOIN #x")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)
        let reader = harness.attach(buffer.log)
        #expect(await waitUntil { reader.count(of: "lol") == 1 })

        // Two arrivals at that second: the first is the replay of what is on screen, the
        // second is bob saying it again. One key, one hit.
        await harness.server.send("@time=\(Self.iso(when)) :bob!u@h PRIVMSG #x :lol")
        await harness.server.send("@time=\(Self.iso(when)) :bob!u@h PRIVMSG #x :lol")
        await harness.server.send(":bob!u@h PRIVMSG #x :done")
        #expect(await waitUntil { reader.text.contains("done") })

        #expect(reader.count(of: "lol") == 2)
        await harness.shutDown()
    }

    /// A suppressed line must not light the tree up either.
    @Test("a suppressed line raises no activity and catches no URLs")
    func suppressionIsTotal() async throws {
        let chatLog = temporaryChatLog()
        let harness = try await harness(chatLog: chatLog)
        let catcher = URLCatcher()
        harness.connection.urlCatcher = catcher
        let when = try #require(
            ChatLog.date(fromStamp: ChatLog.stamp(Date().addingTimeInterval(-3600)))
        )
        chatLog.write(
            "[\(ChatLog.stamp(when))] <bob> see https://example.com/a",
            network: harness.network,
            buffer: "#swift"
        )
        chatLog.flush()

        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)
        let reader = harness.attach(buffer.log)
        #expect(await waitUntil { reader.text.contains("example.com") })
        buffer.activity = .none

        await harness.server.send(
            "@time=\(Self.iso(when)) :bob!u@h PRIVMSG #swift :see https://example.com/a"
        )
        // The barrier lands in the *status* window, so waiting for it proves the replay has
        // been through `append(_:)` without itself touching the channel we are asserting on.
        await harness.server.send(":irc.example.org NOTICE alice :barrier")
        let status = harness.attach(harness.connection.log)
        #expect(await waitUntil { status.text.contains("barrier") })

        #expect(reader.count(of: "example.com") == 1)
        // The three suppression points, all of them: the line, the catcher and the tree.
        #expect(catcher.entries.isEmpty)
        #expect(buffer.activity == .none)
        await harness.shutDown()
    }

    // MARK: - Backfill for a conversation

    /// Prompt 5's note: a channel had `chathistory` and a conversation had none.
    @Test("opening a conversation asks the server for its backlog, once")
    func queryBackfill() async throws {
        let harness = try await harness(
            capabilities: ["draft/chathistory", "batch", "server-time", "message-tags"]
        )
        await harness.connection.openQuery(with: "bob")
        #expect(
            await waitUntil {
                await harness.server.receivedLines().contains("CHATHISTORY LATEST bob * 25")
            }
        )
        // Asking again is a way to bring the window to the front, not a second request.
        await harness.connection.openQuery(with: "bob")
        await harness.connection.openQuery(with: "bob")
        let requests = await harness.server.receivedLines()
            .filter { $0.hasPrefix("CHATHISTORY") }
        #expect(requests.count == 1)
        await harness.shutDown()
    }

    @Test("a server without chathistory is asked for nothing")
    func noBackfillWithoutTheCapability() async throws {
        let harness = try await harness()
        await harness.connection.openQuery(with: "bob")
        // Give a request that should not exist time to turn up.
        await harness.server.send(":bob!u@h PRIVMSG alice :hello")
        #expect(await waitUntil { harness.connection.queries.first?.nick.raw == "bob" })
        #expect(await !harness.server.receivedLines().contains { $0.hasPrefix("CHATHISTORY") })
        await harness.shutDown()
    }

    /// `server-time`'s wire format, to the second — which is the precision the log's stamp
    /// has and therefore the precision the comparison happens at.
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
