import CaravanTestSupport
import Diagnostics
import IRCProtocol
import IRCTransport
import Testing

@testable import IRCSession

/// CTCP as the session actually drives it: a real socket, a real reply going back out,
/// and the throttle biting on a real flood.
///
/// The prompt's acceptance criterion in unit form — "receive a CTCP VERSION and watch it
/// answer once; receive fifty and watch it answer far fewer" — because a rate limit that
/// is only tested against its own arithmetic is a rate limit nobody has watched work.
@Suite("CTCP over a session")
struct CTCPSessionTests {
    private func session(port: UInt16) -> IRCSession {
        IRCSession(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: port,
                tls: .disabled,
                nick: "alice",
                realName: "Alice Example",
                clientVersion: "Caravan test",
                connectTimeout: .seconds(5),
                backoff: BackoffPolicy(initialDelay: .milliseconds(50), multiplier: 1)
            ),
            trace: TraceBuffer(capacity: 2048)
        )
    }

    /// Connects, registers and hands back everything needed to drive the exchange.
    private func connected(
        _ server: ScriptedIRCServer,
        port: UInt16
    ) async throws -> (IRCSession, StreamLog<IRCEvent>) {
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
        return (session, events)
    }

    /// The reply goes back as a `NOTICE`, to the sender, wrapped. Every one of those is
    /// load-bearing: a `PRIVMSG` reply would be read as a request in turn.
    @Test("a VERSION request is answered once, by NOTICE, to whoever asked")
    func answersVersion() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let (session, events) = try await connected(server, port: port)

        await server.send(":bob!u@h PRIVMSG alice :\u{01}VERSION\u{01}")
        #expect(
            await waitUntil {
                await server.receivedLines().contains { $0.hasPrefix("NOTICE bob") }
            }
        )

        let replies = await server.receivedLines().filter { $0.hasPrefix("NOTICE bob") }
        #expect(replies == ["NOTICE bob :\u{01}VERSION Caravan test\u{01}"])

        // And the request itself is a line in the buffer, not a silent answer.
        #expect(
            await events.snapshot().contains {
                if case .ctcpRequest(_, _, let request, _) = $0 {
                    request.keyword == "VERSION"
                } else {
                    false
                }
            }
        )

        await session.disconnect()
        await server.stop()
    }

    /// **The amplifier test.** Fifty requests, and far fewer answers — plus one line
    /// saying so, rather than forty-five of them.
    @Test("fifty requests produce a handful of replies and one explanation")
    func floodIsThrottled() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let (session, events) = try await connected(server, port: port)

        for _ in 0..<50 {
            await server.send(":mallory!u@h PRIVMSG alice :\u{01}VERSION\u{01}")
        }
        #expect(
            await waitUntil {
                await events.snapshot().filter {
                    if case .ctcpRequest = $0 { true } else { false }
                }
                .count == 50
            }
        )

        let replies = await server.receivedLines().filter { $0.hasPrefix("NOTICE mallory") }
        #expect(replies.count < 50)
        #expect(replies.count <= 5, "the burst size is the ceiling, got \(replies.count)")
        #expect(!replies.isEmpty, "the first few should still be answered")

        let explanations = await events.snapshot().filter {
            if case .clientNotice(let text) = $0 { text.contains("CTCP") } else { false }
        }
        #expect(explanations.count == 1, "said once per burst, not once per request")

        await session.disconnect()
        await server.stop()
    }

    /// A CTCP arriving in a `NOTICE` is an answer. Replying to one is how two clients
    /// talk to each other forever.
    @Test("a CTCP reply is never answered")
    func repliesAreNotAnswered() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let (session, events) = try await connected(server, port: port)

        await server.send(":bob!u@h NOTICE alice :\u{01}VERSION mIRC v7.75\u{01}")
        #expect(
            await waitUntil {
                await events.snapshot().contains { if case .ctcpReply = $0 { true } else { false } }
            }
        )
        #expect(await !server.receivedLines().contains { $0.hasPrefix("NOTICE bob") })

        await session.disconnect()
        await server.stop()
    }

    /// `ACTION` is `/me`. Answering one would answer every action in every channel.
    @Test("an ACTION is a message and draws no reply")
    func actionsAreNotAnswered() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let (session, events) = try await connected(server, port: port)

        await server.send(":bob!u@h PRIVMSG alice :\u{01}ACTION waves\u{01}")
        #expect(
            await waitUntil {
                await events.snapshot().contains {
                    if case .message(_, _, let text, _, let isAction, _) = $0 {
                        text == "waves" && isAction
                    } else {
                        false
                    }
                }
            }
        )
        #expect(await !server.receivedLines().contains { $0.hasPrefix("NOTICE bob") })

        await session.disconnect()
        await server.stop()
    }

    /// One person asking, in front of a channel. The answer goes to them, not to the
    /// channel — otherwise the client amplifies the request all by itself.
    @Test("a channel-wide request is answered privately")
    func channelRequestAnsweredPrivately() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let (session, _) = try await connected(server, port: port)

        await server.send(":bob!u@h PRIVMSG #swift :\u{01}VERSION\u{01}")
        #expect(
            await waitUntil {
                await server.receivedLines().contains { $0.hasPrefix("NOTICE bob") }
            }
        )
        #expect(await !server.receivedLines().contains { $0.hasPrefix("NOTICE #swift") })
        #expect(await !server.receivedLines().contains { $0.hasPrefix("PRIVMSG bob") })

        await session.disconnect()
        await server.stop()
    }
}
