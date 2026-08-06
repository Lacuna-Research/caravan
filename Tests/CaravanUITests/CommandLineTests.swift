import AppKit
import CaravanTestSupport
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The command layer end to end: typed into a window, out on a socket.
///
/// The table of input-to-wire-line lives in `CommandParserTests`, where it runs instantly
/// and exhaustively. What this suite proves is the wiring around it — that the active
/// window supplies the target, that errors land as lines rather than silence, and that
/// `/quit` leaves the connection down instead of reconnecting.
@MainActor
@Suite("Command line")
struct CommandLineTests {
    @MainActor
    private final class Harness {
        let server: ScriptedIRCServer
        let model = temporaryModel()
        private var readers: [ObjectIdentifier: NSTextView] = [:]

        init(server: ScriptedIRCServer) {
            self.server = server
        }

        var connection: ConnectionViewModel { model.connection! }

        /// A real text view, because a `MessageLogController` with nowhere to write keeps
        /// its lines queued rather than rendering them.
        func text(of log: MessageLogController) -> String {
            let key = ObjectIdentifier(log)
            if readers[key] == nil {
                let scrollView = log.displayView()
                readers[key] = scrollView.documentView as? NSTextView
            }
            log.flush()
            return readers[key]?.string ?? ""
        }

        func shutDown() async {
            await model.disconnect()
            await server.stop()
        }
    }

    private func harness(nick: String = "alice") async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: nick)

        let harness = Harness(server: server)
        await harness.model.connect(
            using: ConnectionSettings(
                host: "127.0.0.1",
                port: port,
                useTLS: false,
                nick: nick,
                realName: "Alice Example"
            )
        )
        #expect(await waitUntil { harness.model.connection?.isConnected == true })
        #expect(
            await waitUntil {
                await harness.server.receivedLines().contains("USER alice 0 * :Alice Example")
            }
        )
        return harness
    }

    private func sentLines(_ harness: Harness) async -> [String] {
        await harness.server.receivedLines()
    }

    // MARK: - Commands reach the wire

    @Test("a command typed in the status window reaches the server")
    func commandFromStatusWindow() async throws {
        let harness = try await harness()

        await harness.model.submit("/join swift", from: nil)

        #expect(await waitUntil { await sentLines(harness).contains("JOIN #swift") })
        await harness.shutDown()
    }

    /// The active window is what makes `/me` and plain text resolve a target they were
    /// never given.
    @Test("the active window supplies the target for plain text and for /me")
    func activeWindowSuppliesTheTarget() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })

        let target = Target.channel(IRCChannelName("#swift", mapping: .ascii))
        await harness.model.submit("hello there", from: target)
        await harness.model.submit("/me waves", from: target)
        await harness.model.submit("/part", from: target)

        // Waited on the *last* line sent, so the two before it have certainly arrived.
        #expect(await waitUntil { await sentLines(harness).contains("PART #swift") })
        let lines = await sentLines(harness)
        #expect(lines.contains("PRIVMSG #swift :hello there"))
        #expect(lines.contains("PRIVMSG #swift :\u{01}ACTION waves\u{01}"))

        // Parting is not closing: the buffer stays, greyed.
        #expect(harness.connection.channels.count == 1)

        await harness.shutDown()
    }

    // MARK: - Errors are lines

    /// Never crash, never silently drop input. A status window has no target, and saying
    /// so is the requirement.
    @Test("plain text in a status window prints an error and sends nothing")
    func plainTextInStatusWindow() async throws {
        let harness = try await harness()
        let before = await sentLines(harness)

        await harness.model.submit("hello", from: nil)

        #expect(
            await waitUntil {
                harness.text(of: harness.connection.log).contains("not a channel")
            }
        )
        #expect(await sentLines(harness) == before, "nothing may reach the wire")

        await harness.shutDown()
    }

    @Test("an argument error prints usage in the window it was typed in")
    func usageErrorInChannel() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)

        await harness.model.submit(
            "/msg",
            from: .channel(IRCChannelName("#swift", mapping: .ascii))
        )

        #expect(await waitUntil { harness.text(of: buffer.log).contains("Usage: /msg") })
        #expect(!harness.text(of: harness.connection.log).contains("Usage: /msg"))

        await harness.shutDown()
    }

    // MARK: - /quit

    /// A server answers `QUIT` with `ERROR` and closes, which the session would otherwise
    /// read as a failure worth reconnecting from. Going through `disconnect()` is what
    /// marks this one as ours.
    @Test("quit says goodbye and stays down")
    func quitStaysDown() async throws {
        let harness = try await harness()

        await harness.model.submit("/quit so long", from: nil)

        #expect(await waitUntil { await sentLines(harness).contains("QUIT :so long") })
        #expect(await waitUntil { harness.connection.isConnected == false })

        // Long enough for a reconnect to have been attempted if one were scheduled.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.server.connectionCount() == 1)

        await harness.shutDown()
    }

    // MARK: - Per-window state

    /// Both halves belong to the buffer: a history attached to the view would offer the
    /// wrong window's commands, and a line being written would be lost on every glance
    /// at another channel.
    @Test("the input box and its history belong to the buffer, not the view")
    func inputStateIsPerBuffer() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #one")
        await harness.server.send(":alice!u@h JOIN #two")
        #expect(await waitUntil { harness.connection.channels.count == 2 })

        let first = harness.connection.channels[0]
        let second = harness.connection.channels[1]

        first.input.text = "half written in #one"
        second.input.record("/topic in #two")

        #expect(second.input.text.isEmpty)
        #expect(first.input.history.isEmpty)
        #expect(second.input.history == ["/topic in #two"])
        #expect(first.input.text == "half written in #one")

        await harness.shutDown()
    }
}
