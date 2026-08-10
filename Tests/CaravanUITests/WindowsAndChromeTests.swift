import AppKit
import CaravanTestSupport
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// Detaching a buffer into a window of its own (§1, §10).
@MainActor
@Suite("Detached windows")
struct DetachedWindowTests {
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

        /// Lines are coalesced, so reading the scrollback means flushing it first — the
        /// same helper every other suite in this target uses.
        func text(of log: MessageLogController) -> String {
            let key = ObjectIdentifier(log)
            if readers[key] == nil {
                readers[key] = log.displayView().documentView as? NSTextView
            }
            log.flush()
            return readers[key]?.string ?? ""
        }

        func shutDown() async {
            await model.disconnectAll()
            await server.stop()
        }
    }

    private func harness() async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
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

    private func name(_ raw: String) -> IRCChannelName { IRCChannelName(raw, mapping: .ascii) }

    private func joined(_ harness: Harness, _ channel: String) async throws -> ChannelBuffer {
        await harness.server.send(":alice!u@h JOIN \(channel)")
        #expect(await waitUntil { harness.connection.buffer(named: name(channel)) != nil })
        return try #require(harness.connection.buffer(named: name(channel)))
    }

    @Test("detaching moves a buffer out of the chat area and asks for its window")
    func detaching() async throws {
        let harness = try await harness()
        let buffer = try await joined(harness, "#swift")
        let item = AppModel.SidebarItem.channel(
            connection: harness.connection.id,
            channel: buffer.name
        )
        harness.model.selection = item

        harness.model.detachSelected()
        #expect(harness.model.isDetached(item))
        #expect(harness.model.windowToFocus == item)
        // The main window falls back to the network's status buffer rather than showing a
        // buffer that is now somewhere else.
        #expect(harness.model.selection == .status(harness.connection.id))

        await harness.shutDown()
    }

    /// A buffer that lived in neither place would be a buffer you could no longer reach,
    /// so closing a detached window is reattaching rather than a second kind of close.
    @Test("reattaching brings it back and closes the window")
    func reattaching() async throws {
        let harness = try await harness()
        let buffer = try await joined(harness, "#swift")
        let item = AppModel.SidebarItem.channel(
            connection: harness.connection.id,
            channel: buffer.name
        )
        harness.model.detach(item)

        harness.model.reattach(item)
        #expect(!harness.model.isDetached(item))
        #expect(harness.model.windowToClose == item)
        #expect(harness.model.selection == item)

        await harness.shutDown()
    }

    /// **The whole of §10's "same general affordance"**: the canvas detaches through the
    /// same call a channel does, because both are `SidebarItem`s.
    @Test("the canvas detaches through the same affordance as a buffer")
    func canvasDetaches() {
        let model = temporaryModel()
        model.selection = .settingsAndDebug
        model.detachSelected()
        #expect(model.isDetached(.settingsAndDebug))
    }

    /// §10: once ejected, ⌘0 and ⌘, focus that window instead of taking over the chat area.
    @Test("⌘0 focuses the canvas's window once it is ejected")
    func canvasShortcutsFollowTheWindow() async throws {
        let harness = try await harness()
        let buffer = try await joined(harness, "#swift")
        let channel = AppModel.SidebarItem.channel(
            connection: harness.connection.id,
            channel: buffer.name
        )

        // Attached: it takes over the chat area, as it always has.
        harness.model.selection = channel
        harness.model.showSettingsAndDebug()
        #expect(harness.model.selection == .settingsAndDebug)
        #expect(harness.model.windowToFocus == nil)

        // Ejected: the chat area is left alone and the window is raised instead.
        harness.model.detach(.settingsAndDebug)
        harness.model.windowToFocus = nil
        harness.model.selection = channel
        harness.model.showSettingsAndDebug()
        #expect(harness.model.selection == channel)
        #expect(harness.model.windowToFocus == .settingsAndDebug)

        await harness.shutDown()
    }

    /// A window showing a conversation that kept flashing for attention would be absurd.
    @Test("a detached buffer never accumulates activity")
    func detachedBuffersStayQuiet() async throws {
        let harness = try await harness()
        let buffer = try await joined(harness, "#swift")
        let item = AppModel.SidebarItem.channel(
            connection: harness.connection.id,
            channel: buffer.name
        )
        harness.model.detach(item)
        buffer.activity = .none
        // The main window is looking at the status buffer, not at #swift.
        #expect(harness.model.selection == .status(harness.connection.id))

        await harness.server.send(":bob!u@h PRIVMSG #swift :alice: over here")
        // Waited for by its arrival in the scrollback rather than by a bare sleep: the
        // claim is "the line landed and still raised nothing", and a sleep alone would
        // pass just as well on a message that never arrived.
        #expect(await waitUntil { harness.text(of: buffer.log).contains("over here") })
        #expect(buffer.activity == .none)

        await harness.shutDown()
    }

    /// Found by the live run: the canvas belongs to no connection, so falling back to
    /// "this row's network" left the selection nil — and an empty selection is also how the
    /// app says there is nothing to show, so the main window announced "Not connected"
    /// while connected to Libera.
    @Test("detaching the canvas leaves the main window on a real buffer")
    func detachingTheCanvasKeepsASelection() async throws {
        let harness = try await harness()
        _ = try await joined(harness, "#swift")
        harness.model.selection = .settingsAndDebug

        harness.model.detachSelected()
        #expect(harness.model.selection == .status(harness.connection.id))
        #expect(harness.model.activeConnection != nil)

        await harness.shutDown()
    }

    /// Otherwise next-unread, ⌘K and ⌘1–9 would each "go" to a detached buffer by selecting
    /// a row whose chat area only says the buffer is somewhere else — a jump that lands
    /// nowhere.
    @Test("navigating to a detached buffer raises its window instead")
    func revealRaisesTheWindow() async throws {
        let harness = try await harness()
        let buffer = try await joined(harness, "#swift")
        let item = AppModel.SidebarItem.channel(
            connection: harness.connection.id,
            channel: buffer.name
        )
        harness.model.detach(item)
        harness.model.windowToFocus = nil
        let selectionBefore = harness.model.selection

        harness.model.reveal(item)
        #expect(harness.model.windowToFocus == item)
        #expect(harness.model.selection == selectionBefore)

        await harness.shutDown()
    }

    /// Detaching does not take a buffer out of the tree — it is still a buffer of its
    /// network, still navigable, still bindable.
    @Test("a detached buffer stays in the flat list and the tree")
    func staysInTheTree() async throws {
        let harness = try await harness()
        let buffer = try await joined(harness, "#swift")
        let item = AppModel.SidebarItem.channel(
            connection: harness.connection.id,
            channel: buffer.name
        )
        harness.model.detach(item)

        #expect(harness.model.allBuffers.contains { $0.item == item })
        #expect(harness.connection.channels.contains { $0 === buffer })

        await harness.shutDown()
    }

    /// SwiftUI identifies a `WindowGroup`'s windows by a `Codable` value, so every row has
    /// to survive the round trip — including a nick that folds under a casemapping.
    @Test(
        "a sidebar row round-trips through its window value",
        arguments: [
            AppModel.SidebarItem.settingsAndDebug,
            .status(UUID(uuidString: "0DEEA1FA-1111-4444-8888-99999999AAAA")!),
            .channel(
                connection: UUID(uuidString: "0DEEA1FA-1111-4444-8888-99999999AAAA")!,
                channel: IRCChannelName("#swift", mapping: .rfc1459)
            ),
            .query(
                connection: UUID(uuidString: "0DEEA1FA-1111-4444-8888-99999999AAAA")!,
                nick: IRCNick("Foo[]", mapping: .rfc1459)
            ),
            // A channel name may contain almost anything, commas and slashes included.
            .channel(
                connection: UUID(uuidString: "0DEEA1FA-1111-4444-8888-99999999AAAA")!,
                channel: IRCChannelName("#a,b/c", mapping: .ascii)
            ),
            // A canvas that carries a network, which the other two do not.
            .channelList(connection: UUID(uuidString: "0DEEA1FA-1111-4444-8888-99999999AAAA")!),
        ]
    )
    func windowValueRoundTrip(item: AppModel.SidebarItem) throws {
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(AppModel.SidebarItem.self, from: data) == item)
    }
}

/// Manual drag-to-reorder, persisted (§12).
@MainActor
@Suite("Buffer order")
struct BufferOrderTests {
    private func names(_ order: BufferOrder, _ existing: [String], inserting name: String)
        -> [String]
    {
        var result = existing
        result.insert(
            name,
            at: order.insertionIndex(
                for: name,
                among: existing,
                network: "n:1",
                section: .channels
            )
        )
        return result
    }

    /// The default §12 keeps: a buffer nobody has dragged arrives at the end.
    @Test("without a saved order everything keeps join order")
    func joinOrder() {
        let order = BufferOrder(config: temporaryConfig())
        #expect(names(order, ["#a", "#b"], inserting: "#c") == ["#a", "#b", "#c"])
    }

    /// Rejoining `#swift` after a reconnect must not send it to the bottom of a list you
    /// spent time arranging.
    @Test("a dragged buffer comes back where it was put")
    func savedOrderWins() {
        let order = BufferOrder(config: temporaryConfig())
        order.save(["#c", "#a", "#b"], network: "n:1", section: .channels)
        #expect(names(order, [], inserting: "#a") == ["#a"])
        #expect(names(order, ["#c"], inserting: "#a") == ["#c", "#a"])
        #expect(names(order, ["#c", "#b"], inserting: "#a") == ["#c", "#a", "#b"])
    }

    @Test("a buffer nobody dragged sits after the ones they did")
    func unrankedGoesLast() {
        let order = BufferOrder(config: temporaryConfig())
        order.save(["#c", "#a"], network: "n:1", section: .channels)
        #expect(names(order, ["#c", "#zz"], inserting: "#a") == ["#c", "#a", "#zz"])
    }

    @Test("the order is written to the config and read back by the next launch")
    func persistence() {
        let config = temporaryConfig()
        BufferOrder(config: config).save(["#b", "#a"], network: "n:1", section: .channels)
        #expect(config.string("order.n:1.channels") == "#b,#a")

        let reloaded = BufferOrder(config: config)
        #expect(names(reloaded, ["#b"], inserting: "#a") == ["#b", "#a"])
    }

    @Test("channels and conversations are ordered separately")
    func sectionsAreIndependent() {
        let config = temporaryConfig()
        let order = BufferOrder(config: config)
        order.save(["#b", "#a"], network: "n:1", section: .channels)
        order.save(["carol", "bob"], network: "n:1", section: .queries)
        #expect(config.string("order.n:1.channels") == "#b,#a")
        #expect(config.string("order.n:1.queries") == "carol,bob")
    }

    /// The rule prompt 6's carry-forward warned about: reordering must move the property
    /// the tree, the ⌘K palette and next-unread all read, or the keyboard and the mouse
    /// end up disagreeing about where `#swift` is.
    @Test("a drag moves the buffers the whole app navigates by")
    func dragMovesEverything() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let model = temporaryModel()
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
        let connection = try #require(model.activeConnection)

        for channel in ["#a", "#b", "#c"] {
            await server.send(":alice!u@h JOIN \(channel)")
        }
        #expect(await waitUntil { connection.channels.count == 3 })
        #expect(connection.channels.map(\.name.raw) == ["#a", "#b", "#c"])

        // Drag `#c` to the front.
        model.moveChannels(in: connection, fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(connection.channels.map(\.name.raw) == ["#c", "#a", "#b"])
        // The flat list every navigation feature walks moved with it.
        #expect(
            model.allBuffers.map(\.name) == [connection.displayName, "#c", "#a", "#b"]
        )
        // And it was remembered.
        #expect(model.config.string("order.\(connection.networkKey).channels") == "#c,#a,#b")

        await model.disconnectAll()
        await server.stop()
    }

    /// §12's channels-before-queries rule exists to keep channel positions stable as
    /// transient PMs come and go, and dragging must not give it away.
    @Test("queries stay after channels however much either is dragged")
    func sectionsStayOrdered() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let model = temporaryModel()
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
        let connection = try #require(model.activeConnection)

        await server.send(":alice!u@h JOIN #a")
        await server.send(":bob!u@h PRIVMSG alice :hi")
        await server.send(":carol!u@h PRIVMSG alice :hello")
        #expect(
            await waitUntil { connection.channels.count == 1 && connection.queries.count == 2 }
        )

        model.moveQueries(in: connection, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(connection.queries.map(\.nick.raw) == ["carol", "bob"])
        #expect(
            model.allBuffers.map(\.name) == [connection.displayName, "#a", "carol", "bob"]
        )

        await model.disconnectAll()
        await server.stop()
    }
}
