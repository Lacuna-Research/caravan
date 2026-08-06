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

        var connection: ConnectionViewModel { model.connection! }

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

    /// A model whose settings live in their own defaults suite, so a test never writes
    /// into the user's real preferences.
    private func harness(
        nick: String = "alice",
        showsRawTraffic: Bool = false
    ) async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: nick)

        // A defaults suite of this test's own: `ChatSettings` persists on write, and a
        // test suite has no business editing the preferences of whoever runs it.
        let defaults = UserDefaults(suiteName: "com.lacuna-research.caravan.tests")!
        defaults.removePersistentDomain(forName: "com.lacuna-research.caravan.tests")
        let model = AppModel(settings: ChatSettings(defaults: defaults))
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
        #expect(await waitUntil { model.connection?.isConnected == true })
        return harness
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

    /// A `JOIN` or a `MODE` gets no echo — the server will tell us about it in a moment,
    /// and echoing it here would show it twice.
    @Test("only messages are echoed, not every command")
    func onlyMessagesEcho() async throws {
        let harness = try await harness()
        let before = harness.text(of: harness.connection.log)

        await harness.model.submit("/who alice", from: nil)
        try await Task.sleep(for: .milliseconds(120))

        #expect(harness.text(of: harness.connection.log) == before)
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
