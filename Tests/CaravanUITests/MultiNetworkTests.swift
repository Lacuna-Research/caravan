import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// Two networks at once, and one bouncer pretending to be several.
///
/// The claim under test is the prompt's own: **the UI must not care which is in play.**
/// So the assertions are deliberately about `AppModel.connections` and the selection —
/// the things the tree, the command layer and the completion sources actually read — and
/// they are the same assertions for both modes.
@MainActor
@Suite("Multi-network")
struct MultiNetworkTests {
    private struct Network {
        let server: ScriptedIRCServer
        let port: UInt16
    }

    /// A scripted network that welcomes on `CAP END` and calls itself `name`.
    private func network(
        named name: String,
        offering: [String] = [],
        nick: String = "alice"
    ) async throws -> Network {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: nick, offering: offering)
        return Network(server: server, port: port)
    }

    private func settings(port: UInt16, nick: String = "alice") -> ConnectionSettings {
        ConnectionSettings(
            host: "127.0.0.1",
            port: port,
            useTLS: false,
            nick: nick,
            realName: "Alice Example"
        )
    }

    // MARK: - Two direct networks

    @Test("two networks are two rows, each with its own state and channels")
    func twoDirectNetworks() async throws {
        let first = try await network(named: "one")
        let second = try await network(named: "two")
        let model = temporaryModel()

        await model.connect(using: settings(port: first.port))
        await model.connect(using: settings(port: second.port))
        #expect(model.connections.count == 2)
        #expect(await waitUntil { model.connections.allSatisfy(\.isConnected) })

        // Channels belong to their own network, and `#swift` on one is not `#swift` on the
        // other — the rule the tree has enforced since stage 1.
        await first.server.send(":alice!u@h JOIN #swift")
        await second.server.send(":alice!u@h JOIN #vapor")
        #expect(
            await waitUntil {
                model.connections[0].channels.count == 1 && model.connections[1].channels.count == 1
            }
        )
        #expect(model.connections[0].channels.first?.name.raw == "#swift")
        #expect(model.connections[1].channels.first?.name.raw == "#vapor")

        await model.disconnectAll()
        await first.server.stop()
        await second.server.stop()
    }

    /// The selection is what decides where a typed line goes, now that "the connection" is
    /// not a thing. Getting this wrong sends your message to the wrong network.
    @Test("the active network follows the selection")
    func activeNetworkFollowsSelection() async throws {
        let first = try await network(named: "one")
        let second = try await network(named: "two")
        let model = temporaryModel()

        let a = try #require(await model.connect(using: settings(port: first.port)))
        let b = try #require(await model.connect(using: settings(port: second.port)))

        model.selection = .status(a.id)
        #expect(model.activeConnection === a)
        model.selection = .status(b.id)
        #expect(model.activeConnection === b)
        // The canvas is not a network, and neither is nothing.
        model.selection = .settingsAndDebug
        #expect(model.activeConnection == nil)
        model.selection = nil
        #expect(model.activeConnection == nil)

        await model.disconnectAll()
        await first.server.stop()
        await second.server.stop()
    }

    /// Opening the same host twice should select what is already there rather than growing
    /// a second identical row.
    @Test("connecting to a network already open selects it instead of duplicating it")
    func doesNotDuplicate() async throws {
        let only = try await network(named: "one")
        let model = temporaryModel()

        let first = try #require(await model.connect(using: settings(port: only.port)))
        model.selection = .settingsAndDebug
        let again = await model.connect(using: settings(port: only.port))

        #expect(model.connections.count == 1)
        #expect(again === first)
        #expect(model.selection == .status(first.id))

        await model.disconnectAll()
        await only.server.stop()
    }

    /// The `<user>/<network>` fallback: same host, same port, different network. Treating
    /// those as one row would collapse a bouncer's networks into whichever was opened
    /// first.
    @Test("two bouncer networks on one host are two rows")
    func usernameFallbackIsNotDeduplicated() async throws {
        let bouncer = try await network(named: "soju")
        let model = temporaryModel()

        var libera = settings(port: bouncer.port)
        libera.bouncerNetwork = "libera"
        var oftc = settings(port: bouncer.port)
        oftc.bouncerNetwork = "oftc"

        await model.connect(using: libera)
        await model.connect(using: oftc)
        #expect(model.connections.count == 2)
        #expect(model.connections[0].configuration.ident == "alice/libera")
        #expect(model.connections[1].configuration.ident == "alice/oftc")

        await model.disconnectAll()
        await bouncer.server.stop()
    }

    @Test("the username fallback appends the network to the ident")
    func identFallback() {
        var settings = ConnectionSettings(host: "soju.example.org", nick: "alice")
        #expect(settings.sessionConfiguration.ident == "alice")
        settings.bouncerNetwork = "libera"
        #expect(settings.sessionConfiguration.ident == "alice/libera")
        settings.ident = "al"
        #expect(settings.sessionConfiguration.ident == "al/libera")
    }

    // MARK: - The bouncer

    /// **The whole test of the design.** A bouncer's upstream networks arrive as rows that
    /// are indistinguishable from directly-connected ones — same list, same selection, same
    /// everything below it.
    @Test("a bouncer's networks become rows of their own")
    func bouncerNetworksBecomeRows() async throws {
        let bouncer = try await network(
            named: "soju",
            offering: ["soju.im/bouncer-networks", "soju.im/bouncer-networks-notify"]
        )
        await bouncer.server.reply(
            toMessagesMatching: {
                $0.command.isVerb("BOUNCER") && $0.parameters.first == "LISTNETWORKS"
            },
            with: [
                ":bouncer BOUNCER NETWORK 1 name=Libera;state=connected",
                ":bouncer BOUNCER NETWORK 2 name=OFTC;state=connected",
            ]
        )

        let model = temporaryModel()
        let control = try #require(await model.connect(using: settings(port: bouncer.port)))
        // One row for the bouncer itself — where BouncerServ is reachable — and one per
        // upstream network.
        #expect(await waitUntil { model.connections.count == 3 })

        let bound = model.connections.filter { $0.bouncerNetworkID != nil }
        #expect(bound.map(\.bouncerNetworkID) == ["1", "2"])
        #expect(bound.map(\.displayName) == ["Libera", "OFTC"])
        // Each one binds on its own connection, which is what the extension requires.
        #expect(bound.allSatisfy { $0.host == control.host && $0.port == control.port })

        // Discovering networks must not yank the user out of whatever they were reading.
        #expect(model.selection == .status(control.id))

        await model.disconnectAll()
        await bouncer.server.stop()
    }

    /// A network the bouncer lets go takes its row with it: a row that could never
    /// reconnect would be a lie the tree tells.
    @Test("a network the bouncer drops loses its row")
    func droppedNetworkLosesItsRow() async throws {
        let bouncer = try await network(
            named: "soju",
            offering: ["soju.im/bouncer-networks", "soju.im/bouncer-networks-notify"]
        )
        await bouncer.server.reply(
            toMessagesMatching: {
                $0.command.isVerb("BOUNCER") && $0.parameters.first == "LISTNETWORKS"
            },
            with: [":bouncer BOUNCER NETWORK 1 name=Libera;state=connected"]
        )

        let model = temporaryModel()
        let control = try #require(await model.connect(using: settings(port: bouncer.port)))
        #expect(await waitUntil { model.connections.count == 2 })

        await bouncer.server.send(":bouncer BOUNCER NETWORK 1 *")
        #expect(await waitUntil { model.connections.count == 1 })
        #expect(model.connections.first?.bouncerNetworkID == nil)
        // The bouncer itself stays: only the network behind it went away.
        #expect(model.connections.first === control)
        #expect(control.bouncerNetworks.isEmpty)

        await model.disconnectAll()
        await bouncer.server.stop()
    }

    /// Closing the bouncer takes its networks with it — they are reached *through* it.
    @Test("closing a bouncer closes the networks behind it")
    func closingTheBouncerClosesItsNetworks() async throws {
        let bouncer = try await network(
            named: "soju",
            offering: ["soju.im/bouncer-networks"]
        )
        await bouncer.server.reply(
            toMessagesMatching: {
                $0.command.isVerb("BOUNCER") && $0.parameters.first == "LISTNETWORKS"
            },
            with: [":bouncer BOUNCER NETWORK 1 name=Libera;state=connected"]
        )

        let model = temporaryModel()
        let control = try #require(await model.connect(using: settings(port: bouncer.port)))
        #expect(await waitUntil { model.connections.count == 2 })

        await model.close(control)
        #expect(model.connections.isEmpty)
        #expect(model.selection == nil)

        await bouncer.server.stop()
    }

    // MARK: - Expansion

    /// One flag for one network was fine when there was one. Stage 1 prompt 8's
    /// carry-forward asked for this, and with two networks open the old flag collapsed
    /// both at once.
    @Test("each network expands and collapses on its own")
    func expansionIsPerNetwork() async throws {
        let first = try await network(named: "one")
        let second = try await network(named: "two")
        let model = temporaryModel()

        let a = try #require(await model.connect(using: settings(port: first.port)))
        let b = try #require(await model.connect(using: settings(port: second.port)))
        #expect(a.isExpanded)
        #expect(b.isExpanded)

        a.isExpanded = false
        #expect(!a.isExpanded)
        #expect(b.isExpanded)

        await model.disconnectAll()
        await first.server.stop()
        await second.server.stop()
    }

    // MARK: - Naming

    /// `irc.libera.chat` is a hostname; `Libera.Chat` is what the network calls itself, and
    /// it is the better tree row.
    @Test("a network takes its name from ISUPPORT")
    func nameFromISUPPORT() async throws {
        let only = try await network(named: "one")
        let model = temporaryModel()
        let connection = try #require(await model.connect(using: settings(port: only.port)))
        #expect(await waitUntil { connection.isConnected })
        #expect(await waitUntil { connection.displayName == "ExampleNet" })

        await model.disconnectAll()
        await only.server.stop()
    }
}
