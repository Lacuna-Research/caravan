import CaravanTestSupport
import Diagnostics
import IRCProtocol
import IRCTransport
import Testing

@testable import IRCSession

/// Registration and lifecycle, driven by a scripted server over loopback.
///
/// Timeouts are configured in milliseconds so the waiting behaviour is observable in a
/// test rather than merely argued about; the schedule arithmetic itself is covered
/// exhaustively and instantly in `BackoffPolicyTests`.
@Suite("IRCSession")
struct IRCSessionTests {
    private static let nickInUse = ":irc.example.org 433 * alice :Nickname is already in use"

    private struct Harness {
        let server: ScriptedIRCServer
        let session: IRCSession
        let trace: TraceBuffer
        let events: StreamLog<IRCEvent>

        /// Just the lifecycle transitions, in order. The event stream carries everything
        /// now, so the state assertions filter it rather than reading a second stream.
        func states() async -> [SessionState] {
            await events.snapshot().compactMap {
                if case .stateChanged(let state) = $0 { state } else { nil }
            }
        }

        func shutDown() async {
            await session.disconnect()
            await server.stop()
        }
    }

    /// A session pointed at a fresh scripted server, not yet connected.
    private func harness(
        port: UInt16,
        server: ScriptedIRCServer,
        nick: String = "alice",
        altNick: String? = nil,
        password: String? = nil,
        connectTimeout: Duration = .seconds(5),
        idleInterval: Duration = .seconds(60),
        idleResponseTimeout: Duration = .seconds(60)
    ) -> Harness {
        let configuration = SessionConfiguration(
            host: "127.0.0.1",
            port: port,
            tls: .disabled,
            nick: nick,
            altNick: altNick,
            realName: "Alice Example",
            password: password,
            connectTimeout: connectTimeout,
            idleInterval: idleInterval,
            idleResponseTimeout: idleResponseTimeout,
            // No jitter and a short, flat delay: a reconnect test should exercise the
            // reconnect, not the arithmetic.
            backoff: BackoffPolicy(
                initialDelay: .milliseconds(50),
                multiplier: 1,
                maximumDelay: .milliseconds(50),
                jitterFraction: 0
            )
        )
        let trace = TraceBuffer(capacity: 512)
        let session = IRCSession(configuration: configuration, trace: trace)
        let events = StreamLog<IRCEvent>()
        // Subscribed before any connect: the multicast does not replay, so a subscriber
        // that arrives late has genuinely missed what happened.
        events.drain(session.events())
        return Harness(server: server, session: session, trace: trace, events: events)
    }

    private func registeredHarness(nick: String = "alice", password: String? = nil) async throws
        -> Harness
    {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: nick)
        let harness = harness(port: port, server: server, nick: nick, password: password)
        await harness.session.connect()
        #expect(await waitUntil { await harness.states().contains(where: isConnected) })
        return harness
    }

    // MARK: - Registration

    @Test("registers with PASS, NICK and USER, then reports connected")
    func happyPath() async throws {
        let harness = try await registeredHarness(password: "hunter2")

        #expect(
            await harness.server.receivedLines() == [
                "PASS hunter2", "NICK alice", "USER alice 0 * :Alice Example",
            ]
        )
        #expect(await harness.states().prefix(2) == [.connecting, .registering])

        let info = try #require(await harness.session.serverInfo)
        #expect(info.nick == "alice")
        #expect(info.serverName == "irc.example.org")
        #expect(info.version == "caravan-test-1")
        #expect(info.userModes == "iow")
        #expect(info.channelModes == "ov")
        #expect(info.welcome?.hasPrefix("Welcome to the") == true)
        #expect(info.hostInfo?.contains("Your host is") == true)
        #expect(info.created?.contains("created") == true)

        await harness.shutDown()
    }

    /// The credential reaches the wire and nothing else — the same property prompt 4
    /// established for the transport, asserted again at the layer that sends it.
    @Test("the server password is redacted in the trace")
    func passwordRedacted() async throws {
        let harness = try await registeredHarness(password: "hunter2")

        let traced = harness.trace.snapshot().map(\.line)
        #expect(traced.contains("PASS <redacted>"))
        #expect(!traced.joined().contains("hunter2"))

        await harness.shutDown()
    }

    @Test("005 drives the capabilities, including the casemapping")
    func capabilitiesFromISUPPORT() async throws {
        let harness = try await registeredHarness()

        // 005 arrives *after* 001, so being connected is not yet a promise that ISUPPORT
        // has landed. Reading it straight away is a race this test used to win by luck.
        #expect(await waitUntil { await harness.session.capabilities.network == "ExampleNet" })

        let capabilities = await harness.session.capabilities
        #expect(capabilities.nickLength == 30)
        #expect(capabilities.channelTypes == ["#"])
        #expect(await harness.session.caseMapping == .ascii)

        await harness.shutDown()
    }

    @Test("falls back to the alt nick when the first is in use")
    func altNickFallback() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.reply(to: "NICK", with: [Self.nickInUse], repeats: false)
        await server.scriptWelcome(nick: "bob", after: "NICK")

        let harness = harness(port: port, server: server, altNick: "bob")
        await harness.session.connect()
        #expect(await waitUntil { await harness.states().contains(where: isConnected) })

        #expect(await nickLines(harness.server) == ["NICK alice", "NICK bob"])
        #expect(await harness.session.currentNick == "bob")

        await harness.shutDown()
    }

    @Test("appends underscores once the alt nick is taken too")
    func underscoreFallback() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.reply(to: "NICK", with: [Self.nickInUse], repeats: false)
        await server.reply(to: "NICK", with: [Self.nickInUse], repeats: false)
        await server.scriptWelcome(nick: "bob_", after: "NICK")

        let harness = harness(port: port, server: server, altNick: "bob")
        await harness.session.connect()
        #expect(await waitUntil { await harness.states().contains(where: isConnected) })

        #expect(await nickLines(harness.server) == ["NICK alice", "NICK bob", "NICK bob_"])

        await harness.shutDown()
    }

    /// Running out of nicknames is a dead end, not something a reconnect can fix, so it
    /// must stop rather than loop.
    @Test("gives up with a clear error when every candidate is in use")
    func exhaustsNickCandidates() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.reply(to: "NICK", with: [Self.nickInUse])

        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(
            await waitUntil {
                await harness.states().contains {
                    if case .disconnected(.registrationFailed) = $0 { true } else { false }
                }
            }
        )

        // "alice" plus underscores up to the 9-character default NICKLEN.
        #expect(
            await nickLines(harness.server) == [
                "NICK alice", "NICK alice_", "NICK alice__", "NICK alice___", "NICK alice____",
            ]
        )
        // And no reconnect: retrying would produce exactly the same collisions.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !harness.states().contains(where: isReconnecting))

        await harness.shutDown()
    }

    /// 432 says the nick is malformed, not taken. Appending an underscore to a name the
    /// server called invalid just asks the same question again.
    @Test("an erroneous nickname fails immediately rather than retrying")
    func erroneousNickname() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.reply(
            to: "NICK",
            with: [":irc.example.org 432 * alice :Erroneous Nickname"]
        )

        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(
            await waitUntil {
                await harness.states().contains {
                    if case .disconnected(.registrationFailed) = $0 { true } else { false }
                }
            }
        )
        #expect(await nickLines(harness.server) == ["NICK alice"])

        await harness.shutDown()
    }

    // MARK: - Staying connected

    @Test("answers PING with a PONG carrying the same token")
    func pingPong() async throws {
        let harness = try await registeredHarness()

        await harness.server.send("PING :abc123")
        #expect(
            await waitUntil { await harness.server.receivedLines().contains("PONG abc123") }
        )

        await harness.shutDown()
    }

    @Test("treats ERROR as a server-initiated close, with its reason")
    func serverError() async throws {
        let harness = try await registeredHarness()

        await harness.server.send("ERROR :Closing link: ping timeout")
        #expect(
            await waitUntil {
                await harness.states().contains(
                    .disconnected(reason: .serverError("Closing link: ping timeout"))
                )
            }
        )

        await harness.shutDown()
    }

    /// Silence is indistinguishable from a half-open socket until something asks.
    @Test("pings after silence, and gives up when the ping is not answered")
    func idleTimeout() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")

        let harness = harness(
            port: port,
            server: server,
            idleInterval: .milliseconds(100),
            idleResponseTimeout: .milliseconds(100)
        )
        await harness.session.connect()
        #expect(await waitUntil { await harness.states().contains(where: isConnected) })

        // The script answers USER and NICK only, so our PING goes unanswered.
        #expect(
            await waitUntil {
                await harness.server.receivedLines().contains { $0.hasPrefix("PING ") }
            }
        )
        #expect(
            await waitUntil {
                await harness.states().contains(.disconnected(reason: .timedOut))
            }
        )

        await harness.shutDown()
    }

    // MARK: - Reconnecting

    @Test("reconnects and re-registers after the server hangs up")
    func reconnectsAfterHangUp() async throws {
        let harness = try await registeredHarness()

        await harness.server.closeConnection()
        #expect(await waitUntil { await harness.states().contains(where: isReconnecting) })
        #expect(await waitUntil { await harness.server.connectionCount() == 2 })
        #expect(await waitUntil { await nickLines(harness.server).count == 2 })

        // Registration succeeded again, so the attempt counter is back to zero — the
        // next outage starts from the initial delay rather than where this one left off.
        #expect(
            await waitUntil {
                await harness.states().filter(isConnected).count == 2
            }
        )

        await harness.shutDown()
    }

    @Test("a deliberate disconnect does not reconnect")
    func deliberateDisconnectStaysDown() async throws {
        let harness = try await registeredHarness()

        await harness.session.disconnect()
        #expect(
            await waitUntil {
                await harness.states().last == .disconnected(reason: .userInitiated)
            }
        )

        // Several backoff delays' worth of nothing happening.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.states().last == .disconnected(reason: .userInitiated))
        #expect(await !harness.states().contains(where: isReconnecting))
        #expect(await harness.server.connectionCount() == 1)

        await harness.server.stop()
    }

    /// Nothing below this layer will ever end this: the socket is open and healthy, the
    /// server simply never answers. `NWConnection` has no notion of registration, so
    /// without this deadline the session waits in `.registering` forever.
    ///
    /// A silent server rather than an unreachable address, so the test depends on no
    /// network behaviour at all — see the build log on what refused and unroutable
    /// destinations actually do.
    @Test("a connection that never registers times out and retries")
    func connectDeadline() async throws {
        let server = try ScriptedIRCServer()  // No rules: it accepts, then says nothing.
        let port = try await server.start()

        let harness = harness(port: port, server: server, connectTimeout: .milliseconds(200))
        await harness.session.connect()

        #expect(await waitUntil { await harness.server.connectionCount() >= 1 })

        #expect(
            await waitUntil {
                await harness.states().contains(.disconnected(reason: .connectTimedOut))
            }
        )
        #expect(await waitUntil { await harness.states().contains(where: isReconnecting) })

        await harness.shutDown()
    }

    /// A refused connection does end on its own — the failure surfaces through the read
    /// rather than through a connection state — so the session reconnects rather than
    /// waiting out the deadline.
    @Test("a refused connection fails and retries without waiting for the deadline")
    func refusedConnection() async throws {
        let closedServer = try ScriptedIRCServer()
        let deadPort = try await closedServer.start()
        await closedServer.stop()

        let harness = harness(
            port: deadPort,
            server: closedServer,
            connectTimeout: .seconds(30)  // Far longer than this test may take.
        )
        await harness.session.connect()

        #expect(
            await waitUntil {
                await harness.states().contains {
                    if case .disconnected(.transportFailed) = $0 { true } else { false }
                }
            }
        )
        #expect(await waitUntil { await harness.states().contains(where: isReconnecting) })

        await harness.session.disconnect()
    }

    @Test("connecting while an attempt is in flight is ignored")
    func connectIsIgnoredWhileActive() async throws {
        let harness = try await registeredHarness()

        await harness.session.connect()
        await harness.session.connect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.server.connectionCount() == 1)

        await harness.shutDown()
    }

    // MARK: - Helpers

    private func nickLines(_ server: ScriptedIRCServer) async -> [String] {
        await server.receivedLines().filter { $0.hasPrefix("NICK ") }
    }
}

private func isConnected(_ state: SessionState) -> Bool {
    if case .connected = state { true } else { false }
}

private func isReconnecting(_ state: SessionState) -> Bool {
    if case .reconnecting = state { true } else { false }
}
