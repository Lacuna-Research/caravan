import CaravanTestSupport
import Diagnostics
import IRCProtocol
import IRCTransport
import Testing

@testable import IRCSession

/// The event seam as the session actually drives it, rather than as the translator
/// computes it: ordering, the lifecycle events nothing else can produce, and more than
/// one consumer at a time.
@Suite("Session events")
struct SessionEventTests {
    private func session(port: UInt16) -> IRCSession {
        IRCSession(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: port,
                tls: .disabled,
                nick: "alice",
                realName: "Alice Example",
                connectTimeout: .seconds(5),
                backoff: BackoffPolicy(initialDelay: .milliseconds(50), multiplier: 1)
            ),
            trace: TraceBuffer(capacity: 512)
        )
    }

    /// 001 is three events: the line itself, the registration signal, and the state
    /// transition — in that order, every time.
    @Test("registration emits .raw, then .registered, then .stateChanged")
    func registrationOrdering() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")

        let session = session(port: port)
        let events = StreamLog<IRCEvent>()
        events.drain(session.events())

        await session.connect()
        #expect(
            await waitUntil {
                await events.snapshot().contains {
                    if case .registered = $0 { true } else { false }
                }
            }
        )

        let all = await events.snapshot()
        let welcomeIndex = try #require(
            all.firstIndex { event in
                if case .raw(let message) = event {
                    message.command.numericCode == 1
                } else {
                    false
                }
            }
        )
        guard case .registered(let info) = all[welcomeIndex + 1] else {
            Issue.record("expected .registered immediately after the 001 line")
            return
        }
        #expect(all[welcomeIndex + 2] == .stateChanged(.connected(info)))
        #expect(info.nick == "alice")

        await session.disconnect()
        await server.stop()
    }

    /// The `.raw` guarantee end to end: the session answers PING itself, and the line is
    /// still delivered to everything above.
    @Test("a PING the session answers is still emitted as .raw")
    func pingIsVisible() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")

        let session = session(port: port)
        let events = StreamLog<IRCEvent>()
        events.drain(session.events())
        await session.connect()
        #expect(
            await waitUntil {
                await events.snapshot().contains {
                    if case .registered = $0 { true } else { false }
                }
            }
        )

        await server.send("PING :12345")
        #expect(
            await waitUntil {
                await events.snapshot().contains { event in
                    if case .raw(let message) = event {
                        message.command.isVerb("PING")
                    } else {
                        false
                    }
                }
            }
        )
        // Answered as well as reported.
        #expect(await waitUntil { await server.receivedLines().contains("PONG 12345") })

        await session.disconnect()
        await server.stop()
    }

    /// The reason the multicast exists: the UI and the logger both want the whole feed.
    @Test("two consumers each receive the whole registration")
    func twoConsumers() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")

        let session = session(port: port)
        let first = StreamLog<IRCEvent>()
        let second = StreamLog<IRCEvent>()
        first.drain(session.events())
        second.drain(session.events())

        await session.connect()
        for log in [first, second] {
            #expect(
                await waitUntil {
                    await log.snapshot().contains {
                        if case .registered = $0 { true } else { false }
                    }
                }
            )
        }
        #expect(await first.snapshot() == second.snapshot())

        await session.disconnect()
        await server.stop()
    }

    @Test("a disconnected send is reported to the user, not just the log")
    func clientErrorOnDisconnectedSend() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()

        let session = session(port: port)
        let events = StreamLog<IRCEvent>()
        events.drain(session.events())

        await session.send(IRCMessage(verb: "PRIVMSG", parameters: ["#swift", "anyone there"]))
        #expect(
            await waitUntil {
                await events.snapshot().contains {
                    if case .clientError = $0 { true } else { false }
                }
            }
        )

        await server.stop()
    }

    /// A failure is two events, not one: `.reconnecting` says an attempt is coming and
    /// carries no reason, so dropping the `.disconnected` before it would lose the only
    /// answer to "why?".
    @Test("a failure emits the disconnect reason before the reconnect")
    func disconnectReasonPrecedesReconnect() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")

        let session = session(port: port)
        let events = StreamLog<IRCEvent>()
        events.drain(session.events())
        await session.connect()
        #expect(
            await waitUntil {
                await events.snapshot().contains {
                    if case .registered = $0 { true } else { false }
                }
            }
        )

        await server.send("ERROR :Closing link: ping timeout")
        #expect(
            await waitUntil {
                await events.snapshot().contains {
                    $0
                        == .stateChanged(
                            .disconnected(reason: .serverError("Closing link: ping timeout"))
                        )
                }
            }
        )

        let states = await events.snapshot().compactMap { event -> SessionState? in
            if case .stateChanged(let state) = event { state } else { nil }
        }
        let disconnectIndex = try #require(
            states.firstIndex(of: .disconnected(reason: .serverError("Closing link: ping timeout")))
        )
        guard case .reconnecting = states[disconnectIndex + 1] else {
            Issue.record("expected .reconnecting immediately after the disconnect")
            return
        }

        await session.disconnect()
        await server.stop()
    }
}
