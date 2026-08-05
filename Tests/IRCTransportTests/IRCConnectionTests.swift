import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import Testing

@testable import IRCTransport

/// Integration tests against a real loopback listener. No mock of `NWConnection`: the
/// bugs worth catching here — framing across reads, ordering, who reports what when the
/// socket closes — only exist once there is a socket.
@Suite("IRCConnection")
struct IRCConnectionTests {
    /// Server, connection, and drained streams, wired together and connected.
    private struct Harness {
        let server: ScriptedIRCServer
        let connection: IRCConnection
        let trace: TraceBuffer
        let states: StreamLog<TransportState>
        let inbound: StreamLog<IRCMessage>
    }

    private func connectedHarness() async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()

        let trace = TraceBuffer(capacity: 256)
        let connection = IRCConnection(trace: trace)
        let states = StreamLog<TransportState>()
        let inbound = StreamLog<IRCMessage>()
        states.drain(connection.state)
        inbound.drain(connection.inbound)

        await connection.connect(host: "127.0.0.1", port: port, tls: .disabled)
        #expect(await waitUntil { await states.snapshot().contains(.ready) })
        // The client is `.ready` the moment TCP completes, which is *before* the server
        // has finished accepting: its listener callback still has an actor hop to make.
        // Anything the server sends in that window goes to a nil connection and is
        // dropped, so a test that sends immediately after connecting would flake — and
        // on a loaded CI runner, did.
        #expect(await waitUntil { await server.connectionCount() >= 1 })

        return Harness(
            server: server,
            connection: connection,
            trace: trace,
            states: states,
            inbound: inbound
        )
    }

    @Test("reports idle, then connecting, then ready")
    func reachesReady() async throws {
        let harness = try await connectedHarness()
        #expect(await harness.states.snapshot() == [.idle, .connecting, .ready])
        await harness.connection.disconnect()
        await harness.server.stop()
    }

    @Test("sends messages to the wire in order")
    func sendsInOrder() async throws {
        let harness = try await connectedHarness()

        for index in 1...50 {
            await harness.connection.send(
                IRCMessage(verb: "PRIVMSG", parameters: ["#x", "line \(index)"])
            )
        }
        #expect(await waitUntil { await harness.server.receivedLines().count == 50 })
        #expect(
            await harness.server.receivedLines() == (1...50).map { "PRIVMSG #x :line \($0)" }
        )

        await harness.connection.disconnect()
        await harness.server.stop()
    }

    @Test("parses inbound messages, including ones split across reads")
    func receivesMessages() async throws {
        let harness = try await connectedHarness()

        await harness.server.send(
            ":irc.example.org 001 alice :Welcome to the Internet Relay Network"
        )
        await harness.server.send("PING :12345")
        #expect(await waitUntil { await harness.inbound.count() == 2 })

        let messages = await harness.inbound.snapshot()
        #expect(messages[0].command == .numeric(1))
        #expect(messages[0].source == .server("irc.example.org"))
        #expect(messages[0].parameters == ["alice", "Welcome to the Internet Relay Network"])
        #expect(messages[1].command == .verb("PING"))
        #expect(messages[1].parameters == ["12345"])

        await harness.connection.disconnect()
        await harness.server.stop()
    }

    /// The property the whole redaction design exists for: the credential is intact on
    /// the wire — an IRC server that received `<redacted>` would reject it — and absent
    /// from the trace, because redaction happens on insert.
    @Test("a PASS reaches the wire intact but is redacted in the trace")
    func passIsRedactedInTraceOnly() async throws {
        let harness = try await connectedHarness()

        await harness.connection.send(IRCMessage(verb: "PASS", parameters: ["hunter2"]))
        await harness.connection.send(IRCMessage(verb: "NICK", parameters: ["alice"]))
        #expect(await waitUntil { await harness.server.receivedLines().count == 2 })
        #expect(await harness.server.receivedLines() == ["PASS hunter2", "NICK alice"])

        let traced = harness.trace.snapshot()
        #expect(traced.map(\.line) == ["PASS <redacted>", "NICK alice"])
        #expect(traced.allSatisfy { $0.direction == .outbound })
        #expect(!traced.map(\.line).joined().contains("hunter2"))

        await harness.connection.disconnect()
        await harness.server.stop()
    }

    @Test("traces inbound lines too, before parsing")
    func tracesInbound() async throws {
        let harness = try await connectedHarness()

        await harness.server.send("PING :1")
        await harness.server.send("this is not a valid irc line but it is still traffic")
        #expect(await waitUntil { harness.trace.count == 2 })

        let traced = harness.trace.snapshot()
        #expect(traced.map(\.direction) == [.inbound, .inbound])
        #expect(
            traced.map(\.line) == [
                "PING :1", "this is not a valid irc line but it is still traffic",
            ]
        )

        await harness.connection.disconnect()
        await harness.server.stop()
    }

    @Test("a deliberate disconnect is cancelled, not failed, and is idempotent")
    func disconnectIsCancellation() async throws {
        let harness = try await connectedHarness()

        await harness.connection.disconnect()
        await harness.connection.disconnect()
        await harness.connection.disconnect()

        #expect(await waitUntil { await harness.states.snapshot().last == .cancelled })
        // A second terminal state would mean a caller could see `.cancelled` twice, or a
        // spurious `.failed` chasing it once the socket tears down.
        #expect(await harness.states.snapshot() == [.idle, .connecting, .ready, .cancelled])

        await harness.server.stop()
    }

    @Test("the streams finish once the connection is done")
    func streamsFinish() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        let connection = IRCConnection(trace: TraceBuffer(capacity: 8))
        // One consumer per stream: `AsyncStream` is single-shot, which is why prompt 6
        // introduces a multicast rather than handing this one out twice.
        let inboundDrained = StreamLog<IRCMessage>().drain(connection.inbound)
        let statesDrained = StreamLog<TransportState>().drain(connection.state)

        await connection.connect(host: "127.0.0.1", port: port, tls: .disabled)
        await connection.disconnect()

        await inboundDrained.value  // Hangs if the streams are never finished.
        await statesDrained.value
        await server.stop()
    }

    /// The server hanging up is not the same event as the user leaving — prompt 5
    /// reconnects after one and not the other.
    @Test("a peer close is a failure, distinguishable from a disconnect")
    func peerCloseIsFailure() async throws {
        let harness = try await connectedHarness()

        await harness.server.closeConnection()
        #expect(await waitUntil { await harness.states.snapshot().last == .failed(.closedByPeer) })

        await harness.server.stop()
    }

    @Test("connecting twice on one instance is refused")
    func connectIsSingleShot() async throws {
        let harness = try await connectedHarness()
        await harness.connection.connect(host: "127.0.0.1", port: 6667, tls: .disabled)
        #expect(await harness.states.snapshot() == [.idle, .connecting, .ready])
        await harness.connection.disconnect()
        await harness.server.stop()
    }

    @Test("port zero fails before any socket is opened")
    func rejectsPortZero() async {
        let connection = IRCConnection(trace: TraceBuffer(capacity: 8))
        let states = StreamLog<TransportState>()
        states.drain(connection.state)

        await connection.connect(host: "127.0.0.1", port: 0, tls: .disabled)
        #expect(await waitUntil { await states.snapshot().last == .failed(.invalidPort(0)) })
    }

    /// Truncation rather than silent corruption: the server would cut an overlong line
    /// anyway, and cutting it here keeps the trace agreeing with the wire.
    @Test("an overlong outbound message is truncated to the protocol limit")
    func truncatesOverlongOutbound() async throws {
        let harness = try await connectedHarness()

        let text = String(repeating: "word ", count: 200)
        await harness.connection.send(IRCMessage(verb: "PRIVMSG", parameters: ["#x", text]))
        #expect(await waitUntil { await harness.server.receivedLines().count == 1 })

        let line = try #require(await harness.server.receivedLines().first)
        #expect(line.utf8.count == IRCProtocolLimits.maximumMessageBytes - 2)
        #expect(line.hasPrefix("PRIVMSG #x :word word "))
        #expect(harness.trace.snapshot().map(\.line) == [line])

        await harness.connection.disconnect()
        await harness.server.stop()
    }
}
