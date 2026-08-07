import CaravanTestSupport
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// Which network a window's commands reach.
///
/// The whole point of prompt 9's `on connection:` parameter. Until it existed, everything
/// a buffer view sent went to `activeConnection` — the *tree's* selection — so a detached
/// channel window on one network with the main window pointed at another sent every line,
/// and would have sent every context-menu action, to the wrong server.
@MainActor
@Suite("Commands go to their own window's network")
struct BufferConnectionTests {
    private struct Network {
        let server: ScriptedIRCServer
        let port: UInt16
    }

    private func network() async throws -> Network {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: [])
        return Network(server: server, port: port)
    }

    private func settings(port: UInt16) -> ConnectionSettings {
        ConnectionSettings(
            host: "127.0.0.1",
            port: port,
            useTLS: false,
            nick: "alice",
            realName: "Alice Example"
        )
    }

    @Test("a command submitted on a named connection ignores the selection")
    func submitHonoursTheNamedConnection() async throws {
        let first = try await network()
        let second = try await network()
        let model = temporaryModel()

        let a = try #require(await model.connect(using: settings(port: first.port)))
        let b = try #require(await model.connect(using: settings(port: second.port)))
        #expect(await waitUntil { a.isConnected && b.isConnected })

        await first.server.send(":alice!u@h JOIN #here")
        await second.server.send(":alice!u@h JOIN #there")
        #expect(await waitUntil { a.channels.count == 1 && b.channels.count == 1 })

        // The tree is showing the *first* network. The line is typed in the second's
        // window, which is the case a detached buffer puts you in every day.
        model.selection = .status(a.id)
        await model.submit("/whois bob", from: .channel(IRCChannelName("#there")), on: b)

        #expect(await waitUntil { await second.server.receivedLines().contains("WHOIS bob") })
        #expect(await !first.server.receivedLines().contains("WHOIS bob"))

        await model.disconnectAll()
        await first.server.stop()
        await second.server.stop()
    }

    /// The context menu goes through the same path, so this is the same assertion made
    /// from the other end — a menu item chosen in a window whose network is not selected.
    @Test("a context-menu action reaches its own window's network")
    func menuActionHonoursTheNamedConnection() async throws {
        let first = try await network()
        let second = try await network()
        let model = temporaryModel()

        let a = try #require(await model.connect(using: settings(port: first.port)))
        let b = try #require(await model.connect(using: settings(port: second.port)))
        #expect(await waitUntil { a.isConnected && b.isConnected })
        await second.server.send(":alice!u@h JOIN #there")
        #expect(await waitUntil { b.channels.count == 1 })

        model.selection = .status(a.id)
        let channel = IRCChannelName("#there")
        await model.perform(
            .command("/kick bob"),
            on: b,
            from: .channel(channel),
            in: .detached(.channel(connection: b.id, channel: channel))
        )

        #expect(await waitUntil { await second.server.receivedLines().contains("KICK #there bob") })
        #expect(await first.server.receivedLines().allSatisfy { !$0.hasPrefix("KICK") })

        await model.disconnectAll()
        await first.server.stop()
        await second.server.stop()
    }

    /// The catcher's sheet has to open on the window that asked for it, or a link
    /// right-clicked in a detached buffer puts its window behind the main one.
    @Test("the catcher opens on the window it was asked for from")
    func catcherRemembersItsWindow() async throws {
        let only = try await network()
        let model = temporaryModel()
        let connection = try #require(await model.connect(using: settings(port: only.port)))
        #expect(await waitUntil { connection.isConnected })
        await only.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { connection.channels.count == 1 })

        let channel = IRCChannelName("#swift")
        let window = KeyWindow.detached(.channel(connection: connection.id, channel: channel))
        await model.perform(
            .showURLCatcher,
            on: connection,
            from: .channel(channel),
            in: window
        )

        let presentation = try #require(model.urlCatcherPresentation)
        #expect(presentation.window == window)
        #expect(presentation.network == connection.displayName)
        #expect(presentation.buffer == "#swift")

        await model.disconnectAll()
        await only.server.stop()
    }

    /// `canSetModes` is the one thing the menu greys items out on, and it has to be asked
    /// of *this* window's nick rather than of whichever connection the tree has selected.
    @Test("operator status is read from the channel we are actually in")
    func operatorStatusComesFromTheChannel() async throws {
        let only = try await network()
        let model = temporaryModel()
        let connection = try #require(await model.connect(using: settings(port: only.port)))
        #expect(await waitUntil { connection.isConnected })

        await only.server.send(":alice!u@h JOIN #swift")
        await only.server.send(":server 353 alice = #swift :alice bob")
        await only.server.send(":server 366 alice #swift :End of /NAMES list")
        #expect(await waitUntil { connection.channels.count == 1 })
        let buffer = try #require(connection.channels.first)
        #expect(await waitUntil { buffer.memberCount == 2 })
        #expect(buffer.canSetModes(as: "alice") == false)

        await only.server.send(":server MODE #swift +o alice")
        #expect(await waitUntil { buffer.canSetModes(as: "alice") })
        // Somebody who is not in the channel holds nothing, and neither does nobody.
        #expect(buffer.canSetModes(as: "carol") == false)
        #expect(buffer.canSetModes(as: nil) == false)

        await model.disconnectAll()
        await only.server.stop()
    }
}
