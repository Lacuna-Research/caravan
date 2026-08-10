import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import IRCTransport
import Testing

@testable import CaravanUI

/// What the negotiated capabilities change about the *window*.
///
/// The session suite proves the handshake happens; this proves the two consequences a user
/// can see — your own line appearing exactly once, and a replayed line carrying the time it
/// was said rather than the time it arrived.
@MainActor
@Suite("Capabilities in the window")
struct CapabilityBehaviourTests {
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

    /// A connection whose server offers exactly `offering`.
    private func harness(offering: [String]) async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: offering)

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

    private func joinChannel(_ harness: Harness) async throws -> ChannelBuffer {
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        return try #require(harness.connection.channels.first)
    }

    // MARK: - echo-message

    /// Without the capability the server never sends our own messages back, so the client
    /// draws them: one line, locally.
    @Test("without echo-message the client draws its own line")
    func localEchoWithoutTheCapability() async throws {
        let harness = try await harness(offering: ["multi-prefix"])
        let buffer = try await joinChannel(harness)
        #expect(!harness.connection.capabilities.isEnabled(.echoMessage))

        await harness.model.submit("hello there", from: .channel(buffer.name))
        #expect(await waitUntil { harness.text(of: buffer.log).contains("hello there") })
        #expect(harness.text(of: buffer.log).contains("<alice> hello there"))
        await harness.shutDown()
    }

    /// With it, the server's copy is the better one — it carries the time the message was
    /// accepted and arrives in the order everyone else sees — so the local line is the one
    /// that goes. **Exactly once either way** is the acceptance criterion.
    @Test("with echo-message the server's copy is the only one")
    func serverEchoReplacesTheLocalOne() async throws {
        let harness = try await harness(offering: ["echo-message"])
        let buffer = try await joinChannel(harness)
        #expect(harness.connection.capabilities.isEnabled(.echoMessage))

        await harness.model.submit("hello there", from: .channel(buffer.name))
        // Nothing yet: the client did not draw it, and the server has not spoken.
        harness.connection.log.flush()
        #expect(!harness.text(of: buffer.log).contains("hello there"))

        await harness.server.send(":alice!u@h PRIVMSG #swift :hello there")
        #expect(await waitUntil { harness.text(of: buffer.log).contains("hello there") })

        let occurrences =
            harness.text(of: buffer.log).components(separatedBy: "hello there").count - 1
        #expect(occurrences == 1)
        // Still recognised as ours, so it keeps its own colour rather than reading as
        // somebody else's message.
        #expect(harness.text(of: buffer.log).contains("<alice> hello there"))
        await harness.shutDown()
    }

    /// The suppression is on the *echo*, not on the send. A `/join` never had a local echo
    /// and must not acquire one, and the message itself must still reach the wire.
    @Test("echo-message suppresses the echo, not the message")
    func theMessageStillGoesOut() async throws {
        let harness = try await harness(offering: ["echo-message"])
        let buffer = try await joinChannel(harness)
        await harness.model.submit("hello there", from: .channel(buffer.name))
        #expect(
            await waitUntil {
                await harness.server.receivedLines().contains("PRIVMSG #swift :hello there")
            }
        )
        await harness.shutDown()
    }

    // MARK: - server-time

    /// A line replayed out of a backlog was said an hour ago, and stamping it with the
    /// moment it happened to arrive is a client telling the user something untrue.
    @Test("a server-time tag becomes the line's timestamp")
    func serverTimeIsTheTimestamp() async throws {
        let harness = try await harness(offering: ["server-time", "message-tags"])
        let buffer = try await joinChannel(harness)
        await harness.server.send(
            "@time=2011-10-19T16:40:51.620Z :bob!u@h PRIVMSG #swift :from the past"
        )
        #expect(await waitUntil { harness.text(of: buffer.log).contains("from the past") })
        // The default format is `[HH:mm:ss]` in the local zone, so the assertion is on the
        // *seconds*, which no time zone moves.
        #expect(harness.text(of: buffer.log).contains(":51] <bob> from the past"))
        await harness.shutDown()
    }

    /// **Asserts the stamp is now, rather than that it is not `:51`.** The old form failed
    /// once a minute — whenever the suite happened to run during the fifty-first second —
    /// which is a flake that looks like a real failure and was hit during prompt 16.
    @Test("a line without the tag is stamped with now")
    func withoutTheTag() async throws {
        let harness = try await harness(offering: ["server-time"])
        let buffer = try await joinChannel(harness)

        let before = Calendar.current.component(.second, from: Date())
        await harness.server.send(":bob!u@h PRIVMSG #swift :right now")
        #expect(await waitUntil { harness.text(of: buffer.log).contains("right now") })

        // A second either side, because the line is rendered a moment after it is sent.
        let plausible = (0...2).map { String(format: ":%02d]", (before + $0) % 60) }
        let text = harness.text(of: buffer.log)
        #expect(plausible.contains { text.contains("\($0) <bob> right now") })
        await harness.shutDown()
    }

    /// The fractional part is optional in practice and several servers omit it. Falling
    /// back to the arrival time for half the networks would be a silent half-feature.
    @Test("both spellings of the timestamp parse")
    func timestampSpellings() {
        #expect(ConnectionViewModel.parseServerTime("2011-10-19T16:40:51.620Z") != nil)
        #expect(ConnectionViewModel.parseServerTime("2011-10-19T16:40:51Z") != nil)
        #expect(ConnectionViewModel.parseServerTime("yesterday afternoon") == nil)
    }

    // MARK: - What negotiation says out loud

    /// Worth a line, once per connection: which capabilities are on decides whether your
    /// own messages come from the server and whether timestamps are the server's, and when
    /// something later behaves oddly this is the first thing to check.
    @Test("the status window says what was negotiated")
    func negotiationIsReported() async throws {
        let harness = try await harness(offering: ["multi-prefix", "server-time"])
        harness.connection.log.flush()
        let text = harness.text(of: harness.connection.log)
        #expect(text.contains("Capabilities:"))
        #expect(text.contains("multi-prefix"))
        await harness.shutDown()
    }
}
