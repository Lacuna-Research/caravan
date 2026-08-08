import CaravanTestSupport
import Foundation
import IRCSession
import Testing

@testable import CaravanUI

/// Connecting to an entry, and the two defects the acceptance run found in that path.
@MainActor
@Suite("Connecting to an entry")
struct ServerConnectingTests {
    private struct Harness {
        let model: AppModel
        let servers: ServerList
        let config: ConfigFile
    }

    private func harness() -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "caravan-connect-\(UUID().uuidString)")
        let config = ConfigFile(url: directory.appending(path: "caravan.conf"))
        let servers = ServerList(config: ConfigFile(url: directory.appending(path: "servers.conf")))
        let model = AppModel(
            config: config,
            knownHosts: temporaryKnownHosts(),
            credentials: EphemeralCredentialStore(),
            servers: servers
        )
        config.set("alice", forKey: ConnectionSettings.Key.nick)
        return Harness(model: model, servers: servers, config: config)
    }

    private func scriptedServer() async throws -> (ScriptedIRCServer, UInt16) {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: [])
        return (server, port)
    }

    /// **`.notStarted` is not a failure.** The first live run autojoined nothing because the
    /// wait began before the connection had moved off its initial state, read that
    /// `.disconnected` as an ending, and gave up a millisecond in.
    @Test("the initial state is not mistaken for a failed connection")
    func notStartedIsNotAnEnding() {
        #expect(DisconnectReason.notStarted.isNotStarted)
        let endings: [DisconnectReason] = [
            .userInitiated, .timedOut, .connectTimedOut, .trustRefused,
            .serverError("x"), .registrationFailed("x"), .authenticationFailed("x"),
        ]
        for reason in endings {
            #expect(!reason.isNotStarted, "\(reason) should end a wait")
        }
    }

    /// Autojoin and perform, end to end against a real socket — and in that order, because
    /// a `+r` channel turns away anyone who has not identified yet.
    @Test("autojoin and perform run once the server has welcomed us")
    func autojoinAndPerformRun() async throws {
        let (server, port) = try await scriptedServer()
        let harness = harness()

        var entry = ServerEntry(name: "local", host: "127.0.0.1", port: port, useTLS: false)
        entry.perform = ["/msg NickServ identify hunter2"]
        entry.autojoin = ["#swift", "#vapor"]
        harness.servers.save(entry)

        _ = await harness.model.connect(to: entry)
        #expect(await waitUntil { await server.receivedLines().contains("JOIN #swift,#vapor") })

        let lines = await server.receivedLines()
        let performed = try #require(lines.firstIndex(of: "PRIVMSG NickServ :identify hunter2"))
        let joined = try #require(lines.firstIndex(of: "JOIN #swift,#vapor"))
        #expect(performed < joined, "perform has to run before the channels are joined")

        await harness.model.disconnectAll()
        await server.stop()
    }

    /// **The setting had no caller at all.** `connectStartupServers()` was written, the
    /// toggle was drawn and `connect-on-startup` was written to `servers.conf` — and nothing
    /// ever invoked the method, so the setting shipped doing nothing. Prompt 12's live run
    /// found it with a hand-written `servers.conf` and a Dashboard that just sat there.
    ///
    /// This pins the method's behaviour; the caller is `RootView`'s `.task`, which no test
    /// can reach because nothing in a SwiftUI `body` is observable from here.
    @Test("only the entries marked connect-on-startup are dialled")
    func startupServersConnect() async throws {
        let (server, port) = try await scriptedServer()
        let harness = harness()
        var wanted = ServerEntry(name: "auto", host: "127.0.0.1", port: port, useTLS: false)
        wanted.connectsOnStartup = true
        harness.servers.save(wanted)
        // Saved but not marked, and therefore not dialled: the flag is the whole point.
        harness.servers.save(
            ServerEntry(name: "manual", host: "127.0.0.1", port: port, useTLS: false)
        )

        await harness.model.connectStartupServers()
        #expect(harness.model.connections.map(\.networkKey) == ["auto"])

        await harness.model.disconnectAll()
        await server.stop()
    }

    /// A rename has to reach a connection that is already open, or `networkKey` disagrees
    /// with the freshly-rewritten `binding.N` and ⌘3 reports the network as not open while
    /// it sits in the tree.
    @Test("renaming a connected network renames the connection too")
    func renameReachesLiveConnections() async throws {
        let (server, port) = try await scriptedServer()
        let harness = harness()
        let entry = ServerEntry(name: "local", host: "127.0.0.1", port: port, useTLS: false)
        harness.servers.save(entry)

        let connection = try #require(await harness.model.connect(to: entry))
        #expect(await waitUntil { connection.isConnected })
        #expect(connection.networkKey == "local")

        // Bound through the live API rather than by writing the key: `BufferBindings`
        // parses the file once at launch, so a key written afterwards is invisible to it —
        // which would have made this test pass against the very bug it is here for.
        harness.model.bindings.bind(
            BufferBinding(network: "local", buffer: "#swift"),
            to: 3
        )
        #expect(harness.model.renameServer("local", to: "renamed"))

        #expect(connection.networkName == "renamed")
        #expect(connection.networkKey == "renamed")
        // Which is the point: the binding and the live connection still agree.
        #expect(harness.config.string(BufferBindings.key(for: 3)) == "renamed/#swift")
        // **And the in-memory copy, not only the file.** The slots were parsed at launch;
        // leaving them behind cost ⌘3 its badge until the next relaunch.
        #expect(harness.model.bindings.binding(for: 3)?.network == "renamed")

        await harness.model.disconnectAll()
        await server.stop()
    }

    @Test("connecting to an entry already open selects it rather than dialling twice")
    func connectingTwiceIsIdempotent() async throws {
        let (server, port) = try await scriptedServer()
        let harness = harness()
        let entry = ServerEntry(name: "local", host: "127.0.0.1", port: port, useTLS: false)
        harness.servers.save(entry)

        let first = try #require(await harness.model.connect(to: entry))
        #expect(await waitUntil { first.isConnected })
        let again = await harness.model.connect(to: entry)

        #expect(again === first)
        #expect(harness.model.connections.count == 1)

        await harness.model.disconnectAll()
        await server.stop()
    }

    /// The entry's nickname is an override; everything else comes from the global identity
    /// on the Options Connect tab (§15.5's global-first convention).
    @Test("a per-entry nickname overrides the global one, and nothing else does")
    func nicknameOverride() {
        let harness = harness()
        harness.config.set("global", forKey: ConnectionSettings.Key.nick)
        harness.config.set("Global Person", forKey: ConnectionSettings.Key.realName)

        var entry = ServerEntry(name: "local", host: "h", port: 6667, useTLS: false)
        #expect(harness.model.settings(for: entry).nick == "global")

        entry.nick = "special"
        let settings = harness.model.settings(for: entry)
        #expect(settings.nick == "special")
        #expect(settings.realName == "Global Person")
        #expect(settings.host == "h")
        #expect(!settings.useTLS)
    }

    @Test("an entry with no host is not dialled")
    func invalidEntriesAreRefused() async {
        let harness = harness()
        let entry = ServerEntry(name: "blank", host: "")
        #expect(await harness.model.connect(to: entry) == nil)
        #expect(harness.model.connections.isEmpty)
    }
}
