import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The status window's own behaviour: what you said coming back, the MOTD in the band,
/// and the raw-traffic toggle.
@MainActor
@Suite("Status window")
struct StatusWindowTests {
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

        func shutDown() async {
            await model.disconnect()
            await server.stop()
        }
    }

    /// A model whose settings live in their own config file, so a test never writes into
    /// the user's real settings.
    private func harness(
        nick: String = "alice",
        showsRawTraffic: Bool = false
    ) async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: nick)

        let model = temporaryModel()
        model.settings.showsRawTraffic = showsRawTraffic
        let harness = Harness(server: server, model: model)
        await model.connect(
            using: ConnectionSettings(
                host: "127.0.0.1",
                port: port,
                useTLS: false,
                nick: nick,
                realName: "Alice Example"
            )
        )
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        return harness
    }

    // MARK: - Where a numeric lands

    /// **The one that made a refused message look like nothing happening.** Speaking in a
    /// `+m` or `+r` channel is answered with 404, and 404 used to go to the status window —
    /// so the channel showed no echo and no error, and the message was simply gone. Proved
    /// against Libera with a moderated channel before it was fixed here.
    @Test("an error naming an open channel lands in that channel")
    func channelErrorReachesItsChannel() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)

        await harness.server.send(
            ":irc.example.org 404 alice #swift :Cannot send to nick/channel"
        )
        #expect(await waitUntil { harness.text(of: buffer.log).contains("Cannot send") })
        #expect(!harness.text(of: harness.connection.log).contains("Cannot send"))

        await harness.shutDown()
    }

    /// A numeric about a channel we are *not* in has nowhere better to go.
    @Test("an error naming an unopened channel still lands in the status window")
    func unknownChannelStaysInStatus() async throws {
        let harness = try await harness()

        await harness.server.send(
            ":irc.example.org 404 alice #elsewhere :Cannot send to nick/channel"
        )
        #expect(
            await waitUntil { harness.text(of: harness.connection.log).contains("Cannot send") }
        )

        await harness.shutDown()
    }

    /// **Prose is not an argument.** Numerics routinely mention a channel in their trailing
    /// text, and routing on that would put a line in a window because of a sentence.
    @Test("a channel named only in the trailing text does not steal the line")
    func trailingTextIsNotRouting() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)

        // The channel appears only as the human-readable tail.
        await harness.server.send(":irc.example.org 461 alice :You are not on #swift")
        #expect(await waitUntil { harness.text(of: harness.connection.log).contains("not on") })
        #expect(!harness.text(of: buffer.log).contains("not on"))

        await harness.shutDown()
    }

    // MARK: - Local echo

    /// Without `echo-message` the server does not send our own messages back, so a client
    /// that only rendered inbound traffic would never show what you typed.
    @Test("what we say is echoed locally, in the nick column")
    func selfEcho() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)
        let target = Target.channel(IRCChannelName("#swift", mapping: .ascii))

        await harness.model.submit("hello there", from: target)
        await harness.model.submit("/me waves", from: target)

        #expect(await waitUntil { harness.text(of: buffer.log).contains("<alice> hello there") })
        #expect(harness.text(of: buffer.log).contains("* alice waves"))
        // The wire form is not in the buffer: that belongs behind the raw toggle.
        #expect(!harness.text(of: buffer.log).contains("PRIVMSG"))

        await harness.shutDown()
    }

    /// A `WHO` or a `MODE` gets no echo — the server will tell us about it in a moment,
    /// and echoing it here would show it twice.
    ///
    /// Asserted as "no line attributed to us" rather than "the buffer did not change":
    /// the buffer *does* change, because `WHO`'s numeric replies land in it, and the first
    /// version of this test only passed on a machine slow enough for them not to have
    /// arrived yet.
    @Test("only messages are echoed, not every command")
    func onlyMessagesEcho() async throws {
        let harness = try await harness()

        await harness.model.submit("/who alice", from: nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!harness.text(of: harness.connection.log).contains("<alice>"))

        // The contrast, in the same window: a message does echo.
        await harness.model.submit("/msg bob hi there", from: nil)
        #expect(
            await waitUntil {
                harness.text(of: harness.connection.log).contains("-> *bob* hi there")
            }
        )

        await harness.shutDown()
    }

    /// Found by the stage 1 acceptance run: `/msg bob hi` typed in `#swift` was echoed
    /// `<@alice> hi`, indistinguishable from something said in the channel. The message
    /// went to bob; a client that renders it as a channel line is lying about where your
    /// words went.
    @Test("a message addressed elsewhere is marked as going elsewhere")
    func echoOfAMessageSentElsewhere() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)
        let target = Target.channel(IRCChannelName("#swift", mapping: .ascii))

        await harness.model.submit("/msg bob a word in private", from: target)
        await harness.model.submit("/notice carol heads up", from: target)
        await harness.model.submit("in the channel", from: target)

        #expect(await waitUntil { harness.text(of: buffer.log).contains("in the channel") })
        let text = harness.text(of: buffer.log)
        // The recipient is in the nick column, and the arrow says it left the window.
        #expect(text.contains("-> *bob* a word in private"))
        #expect(text.contains("-> -carol- heads up"))
        // What was actually said here still reads as ours.
        #expect(text.contains("<alice> in the channel"))

        await harness.shutDown()
    }

    /// The window's own target is still the window's own target, whatever its case.
    @Test("a message to this window, differently cased, is still this window")
    func echoIsCaseInsensitive() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        let buffer = try #require(harness.connection.channels.first)
        let target = Target.channel(IRCChannelName("#swift", mapping: .ascii))

        await harness.model.submit("/msg #SWIFT shouted", from: target)
        #expect(await waitUntil { harness.text(of: buffer.log).contains("shouted") })
        #expect(!harness.text(of: buffer.log).contains("-> *#SWIFT*"))

        await harness.shutDown()
    }

    // MARK: - Raw traffic

    @Test("wire traffic is hidden until the toggle is on")
    func rawTrafficIsOffByDefault() async throws {
        let harness = try await harness()
        #expect(!harness.text(of: harness.connection.log).contains("<< "))
        #expect(!harness.text(of: harness.connection.log).contains(">> "))
        await harness.shutDown()
    }

    @Test("with the toggle on, both directions land in the status window")
    func rawTrafficBothDirections() async throws {
        let harness = try await harness(showsRawTraffic: true)

        await harness.model.submit("/who alice", from: nil)
        await harness.server.send(":irc.example.org 315 alice alice :End of /WHO list")

        #expect(
            await waitUntil { harness.text(of: harness.connection.log).contains(">> WHO alice") }
        )
        #expect(
            await waitUntil {
                harness.text(of: harness.connection.log).contains("<< :irc.example.org 315")
            }
        )
        await harness.shutDown()
    }

    /// The raw view must not be the one place a credential shows up in plaintext.
    @Test("raw lines are redacted")
    func rawTrafficIsRedacted() async throws {
        let harness = try await harness(showsRawTraffic: true)

        await harness.model.submit("/raw PASS hunter2", from: nil)

        #expect(
            await waitUntil { harness.text(of: harness.connection.log).contains("PASS <redacted>") }
        )
        #expect(!harness.text(of: harness.connection.log).contains("hunter2"))
        await harness.shutDown()
    }

    // MARK: - The MOTD band

    /// Published when 376 ends the burst rather than per line, so the band does not grow a
    /// line at a time while a long MOTD streams in.
    @Test("the MOTD is collected for the header band and published at the end")
    func motd() async throws {
        let harness = try await harness()
        #expect(harness.connection.motd == nil)

        await harness.server.send(":irc.example.org 375 alice :- Message of the Day -")
        await harness.server.send(":irc.example.org 372 alice :- first line")
        await harness.server.send(":irc.example.org 372 alice :- second line")
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.connection.motd == nil, "not until 376 closes the burst")

        await harness.server.send(":irc.example.org 376 alice :End of /MOTD command.")
        #expect(await waitUntil { harness.connection.motd != nil })
        #expect(harness.connection.motd == "- first line\n- second line")

        await harness.shutDown()
    }

    @Test("a server with no MOTD says so rather than leaving the band empty")
    func noMOTD() async throws {
        let harness = try await harness()
        await harness.server.send(":irc.example.org 422 alice :MOTD File is missing")
        #expect(await waitUntil { harness.connection.motd == "MOTD File is missing" })
        await harness.shutDown()
    }

    // MARK: - Diagnostics

    /// Safe to paste into a public issue, which is the whole point — and true because the
    /// trace was redacted on insert rather than on the way out.
    @Test("the diagnostics report carries versions and a redacted trace")
    func diagnosticsReport() {
        let trace = TraceBuffer(capacity: 16)
        trace.record(.outbound, line: "PASS hunter2")
        trace.record(.inbound, line: ":irc.example.org 001 alice :Welcome")

        let report = DiagnosticsReport.text(trace: trace)
        #expect(report.hasPrefix("Caravan "))
        #expect(report.contains("macOS "))
        #expect(report.contains(">> PASS <redacted>"))
        #expect(report.contains("<< :irc.example.org 001"))
        #expect(!report.contains("hunter2"))
    }

    @Test("an empty trace still produces a usable report")
    func emptyDiagnosticsReport() {
        let report = DiagnosticsReport.text(trace: TraceBuffer(capacity: 4))
        #expect(report.contains("(no wire traffic recorded)"))
    }
}
