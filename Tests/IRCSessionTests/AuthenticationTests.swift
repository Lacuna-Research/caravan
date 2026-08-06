import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCTransport
import Testing

@testable import IRCSession

/// Capability negotiation and authentication, end to end against a scripted server.
///
/// The unit suites prove the arithmetic; this proves the *sequencing*, which is where the
/// bugs live. Registration is held open by the server until `CAP END`, so an attempt that
/// loses track of its phase does not fail — it hangs, which is the failure mode hardest to
/// find by reading.
@Suite("Authentication")
struct AuthenticationTests {
    private struct Harness {
        let server: ScriptedIRCServer
        let session: IRCSession
        let trace: TraceBuffer
        let events: StreamLog<IRCEvent>

        func isRegistered() async -> Bool {
            await events.snapshot().contains {
                if case .stateChanged(.connected) = $0 { true } else { false }
            }
        }

        func disconnectReason() async -> DisconnectReason? {
            await events.snapshot().reversed().compactMap {
                if case .stateChanged(.disconnected(let reason)) = $0 { reason } else { nil }
            }
            .first
        }

        func capabilities() async -> NegotiatedCapabilities? {
            await events.snapshot().reversed().compactMap {
                if case .capabilitiesChanged(let capabilities) = $0 { capabilities } else { nil }
            }
            .first
        }

        func shutDown() async {
            await session.disconnect()
            await server.stop()
        }
    }

    private func harness(
        port: UInt16,
        server: ScriptedIRCServer,
        authentication: AuthenticationMethod = .none
    ) -> Harness {
        let configuration = SessionConfiguration(
            host: "127.0.0.1",
            port: port,
            tls: .disabled,
            nick: "alice",
            realName: "Alice Example",
            authentication: authentication,
            connectTimeout: .seconds(5),
            // One attempt: an authentication test that quietly reconnected would be
            // asserting against whichever attempt happened to be in flight.
            backoff: BackoffPolicy(
                initialDelay: .seconds(3600),
                multiplier: 1,
                jitterFraction: 0
            )
        )
        let trace = TraceBuffer(capacity: 512)
        let session = IRCSession(configuration: configuration, trace: trace)
        let events = StreamLog<IRCEvent>()
        events.drain(session.events())
        return Harness(server: server, session: session, trace: trace, events: events)
    }

    // MARK: - Negotiation

    @Test("asks for what it can use, ends negotiation, and then registers")
    func negotiatesAndRegisters() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            // A capability we do not know about, to prove we do not ask for it.
            offering: ["multi-prefix", "server-time", "echo-message", "draft/nonsense"]
        )
        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })

        let lines = await server.receivedLines()
        #expect(lines.first == "CAP LS 302")
        let request = try #require(lines.first { $0.hasPrefix("CAP REQ") })
        #expect(request.contains("multi-prefix"))
        #expect(request.contains("server-time"))
        #expect(request.contains("echo-message"))
        #expect(!request.contains("draft/nonsense"))
        // A capability the server never offered is never asked for either.
        #expect(!request.contains("sasl"))
        #expect(lines.contains("CAP END"))

        let capabilities = try #require(await harness.capabilities())
        #expect(capabilities.isEnabled(.multiPrefix))
        #expect(capabilities.isEnabled(.echoMessage))
        await harness.shutDown()
    }

    /// A server with nothing on offer still needs its `CAP END`, or registration never
    /// completes and the attempt dies on the connect deadline instead.
    @Test("a server offering nothing still gets CAP END")
    func nothingOnOffer() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: [])
        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })
        #expect(await server.receivedLines().contains("CAP END"))
        // No `CAP REQ` at all: there was nothing to ask for.
        #expect(await !server.receivedLines().contains { $0.hasPrefix("CAP REQ") })
        await harness.shutDown()
    }

    /// The pre-IRCv3 case, and it must not be a hang: a server that ignores `CAP LS` and
    /// welcomes us anyway is a server we are registered on.
    @Test("a server that ignores CAP still registers")
    func serverWithoutCapabilities() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })
        // Nothing may follow registration: a stray `CAP END` on a registered connection is
        // an error on most ircds.
        #expect(await !server.receivedLines().contains("CAP END"))
        await harness.shutDown()
    }

    @Test("a NAK is reported and does not stall registration")
    func refusedCapabilities() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["multi-prefix"],
            refusing: true
        )
        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })
        #expect(
            await harness.events.snapshot().contains {
                if case .clientNotice(let text) = $0 { text.contains("refused") } else { false }
            }
        )
        #expect(await harness.capabilities()?.isEnabled(.multiPrefix) == false)
        await harness.shutDown()
    }

    // MARK: - SASL

    /// `AUTHENTICATE PLAIN`, an empty challenge, the credential, 900, 903, `CAP END`.
    @Test("SASL PLAIN completes and registration follows")
    func saslPlain() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["sasl=PLAIN", "multi-prefix"]
        )
        await server.reply(
            toMessagesMatching: {
                $0.command.isVerb("AUTHENTICATE") && $0.parameters.first == "PLAIN"
            },
            with: ["AUTHENTICATE +"]
        )
        await server.reply(
            toMessagesMatching: {
                $0.command.isVerb("AUTHENTICATE") && $0.parameters.first != "PLAIN"
            },
            with: [
                ":irc.example.org 900 alice alice!u@h alice :You are now logged in as alice",
                ":irc.example.org 903 alice :SASL authentication successful",
            ]
        )

        let harness = harness(
            port: port,
            server: server,
            authentication: .sasl(mechanism: .plain, account: "alice", password: "hunter2")
        )
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })

        let lines = await server.receivedLines()
        #expect(lines.contains("AUTHENTICATE PLAIN"))
        // The credential reached the wire, base64'd exactly as PLAIN specifies.
        let expected = Data([0] + Array("alice".utf8) + [0] + Array("hunter2".utf8))
        #expect(lines.contains("AUTHENTICATE \(expected.base64EncodedString())"))
        // And `CAP END` waited for the exchange rather than racing it.
        let end = try #require(lines.firstIndex(of: "CAP END"))
        let credential = try #require(
            lines.firstIndex(of: "AUTHENTICATE \(expected.base64EncodedString())")
        )
        #expect(credential < end)

        #expect(
            await harness.events.snapshot().contains {
                if case .authenticated(let account) = $0 { account == "alice" } else { false }
            }
        )
        await harness.shutDown()
    }

    /// **The credential must not survive in the trace.** Redaction happens on insert, so
    /// this is checking the one property that makes "Copy Diagnostics" safe to paste into
    /// a public issue.
    @Test("the SASL credential is redacted in the trace")
    func saslIsRedacted() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: ["sasl=PLAIN"])
        await server.reply(
            toMessagesMatching: {
                $0.command.isVerb("AUTHENTICATE") && $0.parameters.first == "PLAIN"
            },
            with: ["AUTHENTICATE +"]
        )
        await server.reply(
            toMessagesMatching: {
                $0.command.isVerb("AUTHENTICATE") && $0.parameters.first != "PLAIN"
            },
            with: [":irc.example.org 903 alice :SASL authentication successful"]
        )

        let harness = harness(
            port: port,
            server: server,
            authentication: .sasl(mechanism: .plain, account: "alice", password: "hunter2")
        )
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })

        let traced = harness.trace.snapshot().map(\.line)
        let payload = Data([0] + Array("alice".utf8) + [0] + Array("hunter2".utf8))
            .base64EncodedString()
        #expect(!traced.joined().contains(payload))
        #expect(!traced.joined().contains("hunter2"))
        // The mechanism name is not a secret, and losing it would make a failed handshake
        // unreadable in the one place it is meant to be readable.
        #expect(traced.contains("AUTHENTICATE PLAIN"))
        #expect(traced.contains("AUTHENTICATE \(Redactor.placeholder)"))
        await harness.shutDown()
    }

    /// A rejection ends the attempt and does *not* reconnect. A wrong password does not
    /// become right on the second try, and a client that keeps retrying one is how an
    /// account gets locked and an IP gets throttled.
    @Test("a rejected credential fails the attempt without retrying")
    func saslRejected() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["sasl=PLAIN"],
            welcomingOnEnd: false
        )
        await server.reply(
            toMessagesMatching: {
                $0.command.isVerb("AUTHENTICATE") && $0.parameters.first == "PLAIN"
            },
            with: ["AUTHENTICATE +"]
        )
        await server.reply(
            toMessagesMatching: {
                $0.command.isVerb("AUTHENTICATE") && $0.parameters.first != "PLAIN"
            },
            with: [":irc.example.org 904 alice :SASL authentication failed"]
        )

        let harness = harness(
            port: port,
            server: server,
            authentication: .sasl(mechanism: .plain, account: "alice", password: "wrong")
        )
        await harness.session.connect()
        #expect(
            await waitUntil {
                if case .authenticationFailed = await harness.disconnectReason() {
                    true
                } else {
                    false
                }
            }
        )
        #expect(await !harness.isRegistered())
        // One connection: no reconnect was scheduled.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await server.connectionCount() == 1)
        await harness.shutDown()
    }

    /// The fallback the prompt asks for, and the one it does not: no SASL *offered* falls
    /// back to NickServ, because the server cannot do better. A credential the server
    /// *rejected* does not, which the test above pins.
    @Test("a server without SASL falls back to NickServ IDENTIFY")
    func nickServFallback() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: ["multi-prefix"])

        let harness = harness(
            port: port,
            server: server,
            authentication: .sasl(mechanism: .plain, account: "alice", password: "hunter2")
        )
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })
        #expect(
            await waitUntil {
                await server.receivedLines()
                    .contains("PRIVMSG NickServ :IDENTIFY alice hunter2")
            }
        )
        // Said out loud rather than done silently: identifying this way exposes the
        // password to a connection that is registered but not yet authenticated.
        #expect(
            await harness.events.snapshot().contains {
                if case .clientNotice(let text) = $0 { text.contains("NickServ") } else { false }
            }
        )
        // And redacted, by the same rule as everything else.
        #expect(!harness.trace.snapshot().map(\.line).joined().contains("hunter2"))
        await harness.shutDown()
    }

    @Test("NickServ as the configured method identifies after registration")
    func nickServDirect() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: ["sasl=PLAIN"])

        let harness = harness(
            port: port,
            server: server,
            authentication: .nickServ(account: "alice", password: "hunter2")
        )
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })
        // SASL was on offer and deliberately not asked for: the user chose NickServ.
        #expect(await !server.receivedLines().contains { $0.hasPrefix("CAP REQ") })
        #expect(
            await waitUntil {
                await server.receivedLines()
                    .contains("PRIVMSG NickServ :IDENTIFY alice hunter2")
            }
        )
        await harness.shutDown()
    }

    /// Requesting `sasl` and then having nothing to say leaves the server waiting on an
    /// `AUTHENTICATE` that is not coming, which is a hang rather than an error.
    @Test("sasl is not requested when the server lacks the configured mechanism")
    func mechanismNotOffered() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["sasl=EXTERNAL", "multi-prefix"]
        )
        let harness = harness(
            port: port,
            server: server,
            authentication: .sasl(mechanism: .scramSHA256, account: "alice", password: "hunter2")
        )
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })
        let request = try #require(await server.receivedLines().first { $0.hasPrefix("CAP REQ") })
        #expect(!request.contains("sasl"))
        await harness.shutDown()
    }
}
