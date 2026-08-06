import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCTransport
import Testing

@testable import IRCSession

/// soju's bouncer extension, and the backfill that comes with it.
@Suite("Bouncer")
struct BouncerTests {
    // MARK: - Parsing

    private func reply(_ line: String) -> BouncerReply? {
        IRCMessage(line: line).flatMap(BouncerReply.init(message:))
    }

    @Test("a NETWORK line yields its id and attributes")
    func networkLine() throws {
        let parsed = try #require(
            reply(":bouncer BOUNCER NETWORK 42 name=Libera;host=irc.libera.chat;state=connected")
        )
        guard case .network(let id, let attributes) = parsed else {
            Issue.record("expected a network reply")
            return
        }
        #expect(id == "42")
        #expect(attributes?["name"] == "Libera")
        #expect(attributes?["host"] == "irc.libera.chat")
        #expect(attributes?["state"] == "connected")
    }

    /// `<netid> *` is how the extension says a network is gone, and it has to be
    /// distinguishable from a network whose attributes merely happen to be empty.
    @Test("a star means the network was removed")
    func removal() throws {
        let parsed = try #require(reply(":bouncer BOUNCER NETWORK 42 *"))
        #expect(parsed == .network(id: "42", attributes: nil))
    }

    @Test("attribute values are unescaped like ISUPPORT's")
    func escaping() {
        let attributes = BouncerNetwork.parse(attributes: #"name=My\x20Network;host=example.org"#)
        #expect(attributes["name"] == "My Network")
    }

    /// An attribute sent with an empty value is a *removal*, which is how the bouncer
    /// clears an `error` once the upstream comes back.
    @Test("an empty value removes the attribute")
    func emptyValueRemoves() {
        var network = BouncerNetwork(
            id: "1",
            attributes: ["name": "Libera", "error": "connection refused"]
        )
        network.apply(attributes: ["error": ""])
        #expect(network.error == nil)
        #expect(network.displayName == "Libera")
    }

    @Test("the display name falls back from name to host to id")
    func displayName() {
        #expect(BouncerNetwork(id: "1", attributes: ["name": "Libera"]).displayName == "Libera")
        #expect(
            BouncerNetwork(id: "1", attributes: ["host": "irc.x.org"]).displayName == "irc.x.org"
        )
        #expect(BouncerNetwork(id: "1").displayName == "1")
    }

    @Test("state parses, and an unknown one does not pretend to be connected")
    func state() {
        #expect(BouncerNetwork(id: "1", attributes: ["state": "connected"]).state == .connected)
        #expect(BouncerNetwork(id: "1", attributes: ["state": "wobbly"]).state == .unknown)
        #expect(BouncerNetwork(id: "1").state == .unknown)
    }

    @Test("something that is not a BOUNCER NETWORK is not a reply")
    func notABouncerReply() {
        #expect(reply(":s BOUNCER LISTNETWORKS") == nil)
        #expect(reply(":s PRIVMSG #x :hi") == nil)
        #expect(reply(":s BOUNCER NETWORK") == nil)
    }

    // MARK: - The session

    private struct Harness {
        let server: ScriptedIRCServer
        let session: IRCSession
        let events: StreamLog<IRCEvent>

        func isRegistered() async -> Bool {
            await events.snapshot().contains {
                if case .stateChanged(.connected) = $0 { true } else { false }
            }
        }

        func networks() async -> [BouncerNetwork] {
            await events.snapshot().reversed().compactMap {
                if case .bouncerNetworks(let networks) = $0 { networks } else { nil }
            }
            .first ?? []
        }

        func shutDown() async {
            await session.disconnect()
            await server.stop()
        }
    }

    private func harness(
        port: UInt16,
        server: ScriptedIRCServer,
        bouncerNetworkID: String? = nil,
        chatHistoryLimit: Int = 50
    ) -> Harness {
        let session = IRCSession(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: port,
                tls: .disabled,
                nick: "alice",
                realName: "Alice Example",
                chatHistoryLimit: chatHistoryLimit,
                bouncerNetworkID: bouncerNetworkID,
                connectTimeout: .seconds(5),
                backoff: BackoffPolicy(initialDelay: .seconds(3600), multiplier: 1)
            ),
            trace: TraceBuffer(capacity: 512)
        )
        let events = StreamLog<IRCEvent>()
        events.drain(session.events())
        return Harness(server: server, session: session, events: events)
    }

    /// The unbound connection is the only one allowed to enumerate, so it is the only one
    /// that asks.
    @Test("an unbound connection lists the bouncer's networks")
    func listsNetworks() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["soju.im/bouncer-networks", "batch"]
        )
        await server.reply(
            toMessagesMatching: {
                $0.command.isVerb("BOUNCER") && $0.parameters.first == "LISTNETWORKS"
            },
            with: [
                ":bouncer BATCH +net soju.im/bouncer-networks",
                "@batch=net :bouncer BOUNCER NETWORK 1 name=Libera;host=irc.libera.chat;state=connected",
                "@batch=net :bouncer BOUNCER NETWORK 2 name=OFTC;host=irc.oftc.net;state=connecting",
                ":bouncer BATCH -net",
            ]
        )

        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(await waitUntil { await harness.networks().count == 2 })

        let networks = await harness.networks()
        #expect(networks.map(\.id) == ["1", "2"])
        #expect(networks.map(\.displayName) == ["Libera", "OFTC"])
        #expect(networks[0].state == .connected)
        #expect(networks[1].state == .connecting)
        await harness.shutDown()
    }

    /// **`BOUNCER BIND` goes out before `CAP END`, and that is the only window there is.**
    /// The capability must already be acknowledged, and the extension refuses a bind after
    /// registration completes.
    @Test("a bound connection binds during registration, before CAP END")
    func bindsBeforeCapEnd() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["soju.im/bouncer-networks"]
        )

        let harness = harness(port: port, server: server, bouncerNetworkID: "7")
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })

        let lines = await server.receivedLines()
        let bind = try #require(lines.firstIndex(of: "BOUNCER BIND 7"))
        let end = try #require(lines.firstIndex(of: "CAP END"))
        #expect(bind < end)
        // A bound connection must not ask for the network list: it is talking to an
        // upstream network, which knows nothing about the bouncer's others.
        #expect(!lines.contains("BOUNCER LISTNETWORKS"))
        await harness.shutDown()
    }

    /// Carrying on unbound would register us against the bouncer itself and show the wrong
    /// network's traffic under this network's name — quietly, which is the worst of it.
    @Test("a bind that cannot happen fails the attempt rather than connecting anyway")
    func bindWithoutTheCapability() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: ["multi-prefix"])

        let harness = harness(port: port, server: server, bouncerNetworkID: "7")
        await harness.session.connect()
        #expect(
            await waitUntil {
                await harness.events.snapshot().contains {
                    if case .stateChanged(.disconnected(.registrationFailed)) = $0 {
                        true
                    } else {
                        false
                    }
                }
            }
        )
        #expect(await !harness.isRegistered())
        await harness.shutDown()
    }

    /// `cap-notify`'s reason for existing, from the bouncer's side: a network added while
    /// we are attached arrives as a bare `BOUNCER NETWORK`, and the whole list is
    /// re-emitted so the consumer reconciles rather than applying edits.
    @Test("a later NETWORK notification updates the list")
    func notification() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["soju.im/bouncer-networks", "soju.im/bouncer-networks-notify"]
        )
        await server.reply(
            toMessagesMatching: {
                $0.command.isVerb("BOUNCER") && $0.parameters.first == "LISTNETWORKS"
            },
            with: [":bouncer BOUNCER NETWORK 1 name=Libera;state=connected"]
        )

        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(await waitUntil { await harness.networks().count == 1 })

        // An update carries only what changed, and merges over what is known.
        await server.send(":bouncer BOUNCER NETWORK 1 state=disconnected")
        #expect(await waitUntil { await harness.networks().first?.state == .disconnected })
        #expect(await harness.networks().first?.displayName == "Libera")

        await server.send(":bouncer BOUNCER NETWORK 2 name=OFTC")
        #expect(await waitUntil { await harness.networks().count == 2 })

        await server.send(":bouncer BOUNCER NETWORK 1 *")
        #expect(await waitUntil { await harness.networks().map(\.id) == ["2"] })
        await harness.shutDown()
    }

    // MARK: - chathistory

    @Test("joining a channel asks for the recent history")
    func requestsHistory() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["draft/chathistory", "batch", "server-time"]
        )

        let harness = harness(port: port, server: server, chatHistoryLimit: 25)
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })

        await server.send(":alice!u@h JOIN #swift")
        #expect(
            await waitUntil {
                await server.receivedLines().contains("CHATHISTORY LATEST #swift * 25")
            }
        )
        await harness.shutDown()
    }

    /// A busy channel would otherwise produce one request per arrival.
    @Test("somebody else joining asks for nothing")
    func othersDoNotTriggerHistory() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["draft/chathistory", "batch"]
        )

        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })

        await server.send(":bob!u@h JOIN #swift")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !server.receivedLines().contains { $0.hasPrefix("CHATHISTORY") })
        await harness.shutDown()
    }

    @Test("a server without the capability is never asked")
    func noCapabilityNoRequest() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: ["multi-prefix"])

        let harness = harness(port: port, server: server)
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })

        await server.send(":alice!u@h JOIN #swift")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !server.receivedLines().contains { $0.hasPrefix("CHATHISTORY") })
        await harness.shutDown()
    }

    /// Zero is how backfill is turned off, and it has to mean "ask for nothing" rather
    /// than "ask for zero lines".
    @Test("a limit of zero turns backfill off")
    func zeroLimit() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(
            nick: "alice",
            offering: ["draft/chathistory", "batch"]
        )

        let harness = harness(port: port, server: server, chatHistoryLimit: 0)
        await harness.session.connect()
        #expect(await waitUntil { await harness.isRegistered() })

        await server.send(":alice!u@h JOIN #swift")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !server.receivedLines().contains { $0.hasPrefix("CHATHISTORY") })
        await harness.shutDown()
    }
}
