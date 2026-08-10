import AppKit
import CaravanTestSupport
import Diagnostics
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// Which buffer a line lands in, driven by a scripted server over loopback.
///
/// Routing is the whole of what the view model adds over the session: the membership
/// rules are tested where they live, and duplicating them here would only prove that two
/// copies of the same logic agree with each other. What is worth asserting is that a join
/// opens a window, a channel's traffic goes to that window, and a `QUIT` reaches every
/// window that had the user.
@MainActor
@Suite("Channel windows")
struct ChannelWindowTests {
    /// One buffer's rendered text, flushed on demand.
    @MainActor
    private struct Reader {
        let log: MessageLogController
        let textView: NSTextView

        var text: String {
            log.flush()
            return textView.string
        }
    }

    @MainActor
    private struct Harness {
        let server: ScriptedIRCServer
        let connection: ConnectionViewModel

        /// The status window's text, which every harness attaches up front.
        var status: Reader { statusReader }
        private let statusReader: Reader

        init(server: ScriptedIRCServer, connection: ConnectionViewModel) {
            self.server = server
            self.connection = connection
            let textView = MessageLogView.makeTextView(usesTextKit2: false)
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            scrollView.documentView = textView
            connection.log.attach(textView: textView, scrollView: scrollView)
            scrollView.layoutSubtreeIfNeeded()
            self.statusReader = Reader(log: connection.log, textView: textView)
        }

        /// A real text view, because a `MessageLogController` with nowhere to write keeps
        /// its lines queued — the same arrangement the scrollback suite uses.
        @discardableResult
        func attach(_ log: MessageLogController) -> Reader {
            let textView = MessageLogView.makeTextView(usesTextKit2: false)
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            scrollView.documentView = textView
            log.attach(textView: textView, scrollView: scrollView)
            scrollView.layoutSubtreeIfNeeded()
            return Reader(log: log, textView: textView)
        }

        func shutDown() async {
            await connection.disconnect()
            await server.stop()
        }
    }

    private func harness(nick: String = "alice") async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: nick)
        let connection = ConnectionViewModel(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: port,
                tls: .disabled,
                nick: nick,
                realName: "Alice Example"
            ),
            trace: TraceBuffer(capacity: 512)
        )
        let harness = Harness(server: server, connection: connection)
        await connection.connect()
        #expect(await waitUntil { connection.isConnected })
        // 005 lands after 001, and the casemapping it carries keys everything below.
        #expect(await waitUntil { harness.status.text.contains("ExampleNet") })
        return harness
    }

    /// The only event that opens a window — and the join line belongs in the window it
    /// opened, not in the status buffer it was announced through.
    @Test("our own JOIN opens a channel window and the line lands in it")
    func joinOpensAWindow() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")

        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)
        let channel = harness.attach(buffer.log)

        await harness.server.send(":bob!u@h JOIN #swift")
        await harness.server.send(":bob!u@h PRIVMSG #swift :hello there")

        #expect(await waitUntil { channel.text.contains("hello there") })
        #expect(channel.text.contains("Joins: bob"))
        #expect(!harness.status.text.contains("hello there"))

        await harness.shutDown()
    }

    /// mIRC reports a quit in every window that had the user, and nowhere else.
    @Test("a QUIT is reported in every shared channel and not in the status window")
    func quitReachesEveryChannel() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #one")
        await harness.server.send(":alice!u@h JOIN #two")
        #expect(await waitUntil { harness.connection.channels.count == 2 })

        let buffers = harness.connection.channels
        let readers = buffers.map { harness.attach($0.log) }

        await harness.server.send(":bob!u@h JOIN #one")
        await harness.server.send(":bob!u@h JOIN #two")
        #expect(await waitUntil { buffers.allSatisfy { $0.memberCount == 2 } })

        await harness.server.send(":bob!u@h QUIT :Ping timeout")
        for (buffer, reader) in zip(buffers, readers) {
            #expect(await waitUntil { reader.text.contains("Quits: bob") })
            // **Waited for, not asserted outright.** `.channelChanged` is emitted *after*
            // the event that caused it — deliberately, so a consumer draws the quit line
            // and then updates its nick list — so the line appearing does not mean the
            // roster snapshot has landed. Asserting it directly passes locally and failed
            // in CI, which is the whole signature of this kind of race.
            #expect(await waitUntil { buffer.memberCount == 1 })
        }
        #expect(!harness.status.text.contains("Quits: bob"))

        await harness.shutDown()
    }

    /// The nick list is the session's answer, copied. Ordering is `PREFIX` rank then
    /// casemapped alphabetical, and the prefix character is what the pane draws.
    @Test("the nick list shows the session's ordering, prefixes included")
    func nickListOrdering() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        await harness.server.send(":irc.example.org 353 alice = #swift :zoe @bob +carol alice")
        await harness.server.send(":irc.example.org 366 alice #swift :End of /NAMES list")

        #expect(await waitUntil { harness.connection.channels.first?.memberCount == 4 })
        let buffer = try #require(harness.connection.channels.first)
        #expect(
            buffer.members.map(buffer.channel.displayName(for:))
                == ["@bob", "+carol", "alice", "zoe"]
        )
        #expect(buffer.isJoined)

        await harness.shutDown()
    }

    /// A buffer may outlive membership. The window stays, and it stays greyed.
    @Test("being kicked leaves the window open in the not-joined state")
    func kickKeepsTheWindow() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)
        let reader = harness.attach(buffer.log)

        await harness.server.send(":bob!u@h KICK #swift alice :out")
        #expect(await waitUntil { buffer.isJoined == false })
        #expect(harness.connection.channels.count == 1)
        #expect(reader.text.contains("alice was kicked"))

        await harness.shutDown()
    }

    /// Membership never outlives its buffer: closing parts, and only closing removes.
    @Test("closing a channel window parts the channel and removes the row")
    func closingRemovesTheWindow() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })

        await harness.connection.closeChannel(IRCChannelName("#swift", mapping: .ascii))

        #expect(await waitUntil { harness.connection.channels.isEmpty })
        #expect(await harness.server.receivedLines().contains("PART #swift"))

        await harness.shutDown()
    }

    /// A join that failed opened no window, so its error has to land somewhere the user
    /// is actually looking.
    @Test("a join failure is reported in the status window")
    func joinFailureGoesToStatus() async throws {
        let harness = try await harness()
        await harness.server.send(":irc.example.org 475 alice #swift :Cannot join channel (+k)")

        #expect(await waitUntil { harness.status.text.contains("Cannot join #swift") })
        #expect(harness.connection.channels.isEmpty)

        await harness.shutDown()
    }
}
