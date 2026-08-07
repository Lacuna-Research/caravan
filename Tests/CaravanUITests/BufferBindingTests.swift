import CaravanTestSupport
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// ⌘1–9 (GUI-DESIGN-NOTES.md §11): nothing bound by default, bound by hand, remembered.
@MainActor
@Suite("Buffer bindings")
struct BufferBindingTests {
    private func swift() -> BufferBinding {
        BufferBinding(network: "irc.libera.chat:6697", buffer: "#swift")
    }

    @Test("nothing is bound by default")
    func emptyByDefault() {
        let bindings = BufferBindings(config: temporaryConfig())
        #expect(bindings.slots.isEmpty)
        for digit in BufferBindings.digits { #expect(bindings.binding(for: digit) == nil) }
    }

    /// **Bindings survive restarts**, which is the entire point of binding by hand.
    @Test("a binding is written to the config and read back")
    func persistence() {
        let config = temporaryConfig()
        BufferBindings(config: config).bind(swift(), to: 3)

        #expect(config.string("binding.3") == "irc.libera.chat:6697/#swift")
        // A second reader — the next launch.
        #expect(BufferBindings(config: config).binding(for: 3) == swift())
    }

    /// A buffer reachable by two digits makes the tree's own display of the digit a lie.
    @Test("a buffer holds at most one digit, and a digit at most one buffer")
    func exclusivity() {
        let bindings = BufferBindings(config: temporaryConfig())
        bindings.bind(swift(), to: 5)
        bindings.bind(swift(), to: 3)
        #expect(bindings.binding(for: 5) == nil)
        #expect(bindings.binding(for: 3) == swift())
        #expect(bindings.digit(for: swift()) == 3)

        let vapor = BufferBinding(network: "irc.libera.chat:6697", buffer: "#vapor")
        bindings.bind(vapor, to: 3)
        #expect(bindings.binding(for: 3) == vapor)
        #expect(bindings.digit(for: swift()) == nil)
    }

    @Test("clearing forgets, in memory and on disk")
    func clearing() {
        let config = temporaryConfig()
        let bindings = BufferBindings(config: config)
        bindings.bind(swift(), to: 7)
        bindings.clear(7)
        #expect(bindings.binding(for: 7) == nil)
        #expect(config.string("binding.7") == nil)
    }

    @Test("digits outside 1–9 are refused")
    func range() {
        let bindings = BufferBindings(config: temporaryConfig())
        bindings.bind(swift(), to: 0)
        bindings.bind(swift(), to: 10)
        #expect(bindings.slots.isEmpty)
    }

    /// The buffer name keeps its `#`, which is what tells a channel from a conversation
    /// without a third field: `#bob` and `bob` are different buffers.
    @Test(
        "the config value round-trips, and distinguishes a channel from a person",
        arguments: [
            "irc.libera.chat:6697/#swift",
            "irc.libera.chat:6697/bob",
            "irc.libera.chat:6697",
            "soju.example.org:6697[libera]/#swift",
        ]
    )
    func roundTrip(raw: String) throws {
        let binding = try #require(BufferBinding(rawValue: raw))
        #expect(binding.rawValue == raw)
    }

    @Test("a channel and a person of the same name are different bindings")
    func channelIsNotAPerson() throws {
        let channel = try #require(BufferBinding(rawValue: "h:1/#bob"))
        let person = try #require(BufferBinding(rawValue: "h:1/bob"))
        #expect(channel != person)
        #expect(channel.buffer == "#bob")
        #expect(person.buffer == "bob")
    }

    @Test("a status window is the network with no buffer part")
    func statusBinding() throws {
        let binding = try #require(BufferBinding(rawValue: "irc.libera.chat:6697"))
        #expect(binding.buffer.isEmpty)
    }

    @Test("nonsense in the config is ignored rather than crashing")
    func malformed() {
        #expect(BufferBinding(rawValue: "") == nil)
        #expect(BufferBinding(rawValue: "/#swift") == nil)
    }
}

/// Activating a binding, which is where §11's "opens it" and its guard rail live.
@MainActor
@Suite("Activating a binding")
struct BindingActivationTests {
    @MainActor
    private final class Harness {
        let server: ScriptedIRCServer
        let model: AppModel

        init(server: ScriptedIRCServer, model: AppModel) {
            self.server = server
            self.model = model
        }

        var connection: ConnectionViewModel { model.activeConnection! }

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

    @Test("a bound buffer that is open is simply selected")
    func selectsOpenBuffer() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })

        let item = AppModel.SidebarItem.channel(
            connection: harness.connection.id,
            channel: name("#swift")
        )
        let binding = try #require(harness.model.binding(for: item))
        harness.model.bindings.bind(binding, to: 3)
        harness.model.selection = .status(harness.connection.id)

        await harness.model.activateBinding(digit: 3)
        #expect(harness.model.selection == item)

        await harness.shutDown()
    }

    /// ⌘3 means "take me to `#swift`", not "take me to `#swift` if I happen to already be
    /// there".
    @Test("a bound channel that is not open is opened and joined")
    func opensAndJoins() async throws {
        let harness = try await harness()
        let binding = BufferBinding(
            network: harness.connection.bindingNetworkKey,
            buffer: "#later"
        )
        harness.model.bindings.bind(binding, to: 4)

        await harness.model.activateBinding(digit: 4)
        #expect(harness.connection.buffer(named: name("#later")) != nil)
        #expect(
            harness.model.selection
                == .channel(connection: harness.connection.id, channel: name("#later"))
        )
        #expect(await waitUntil { await harness.server.receivedLines().contains("JOIN #later") })

        await harness.shutDown()
    }

    /// **The guard rail** (§11): a binding must not silently dial out. A disconnected
    /// network gets its buffer revealed greyed instead — the same "you are not in here
    /// right now" state a parted channel already wears.
    @Test("a bound channel on a disconnected network is revealed, not dialled")
    func doesNotDialOut() async throws {
        let harness = try await harness()
        let binding = BufferBinding(
            network: harness.connection.bindingNetworkKey,
            buffer: "#later"
        )
        harness.model.bindings.bind(binding, to: 4)
        await harness.model.disconnect()
        #expect(await waitUntil { harness.connection.isConnected == false })
        let linesBefore = await harness.server.receivedLines().count

        await harness.model.activateBinding(digit: 4)
        let buffer = try #require(harness.connection.buffer(named: name("#later")))
        #expect(!buffer.isJoined)
        #expect(
            harness.model.selection
                == .channel(connection: harness.connection.id, channel: name("#later"))
        )
        try await Task.sleep(for: .milliseconds(150))
        #expect(await harness.server.receivedLines().count == linesBefore)

        await harness.shutDown()
    }

    @Test("a bound conversation that is not open is opened")
    func opensQuery() async throws {
        let harness = try await harness()
        let binding = BufferBinding(
            network: harness.connection.bindingNetworkKey,
            buffer: "bob"
        )
        harness.model.bindings.bind(binding, to: 2)

        await harness.model.activateBinding(digit: 2)
        #expect(harness.connection.query(named: IRCNick("bob", mapping: .ascii)) != nil)
        #expect(
            harness.model.selection
                == .query(connection: harness.connection.id, nick: IRCNick("bob", mapping: .ascii))
        )

        await harness.shutDown()
    }

    /// A shortcut that does nothing is indistinguishable from a shortcut that is broken.
    @Test("a binding naming a network that is not open says so")
    func unknownNetwork() async throws {
        let harness = try await harness()
        harness.model.bindings.bind(
            BufferBinding(network: "elsewhere.example.org:6697", buffer: "#gone"),
            to: 9
        )
        let before = harness.model.selection

        await harness.model.activateBinding(digit: 9)
        #expect(harness.model.selection == before)

        await harness.shutDown()
    }

    /// **Binding does not reorder anything** (§11): "pinned" here means remembered.
    @Test("binding leaves the tree order alone")
    func doesNotReorder() async throws {
        let harness = try await harness()
        await harness.server.send(":alice!u@h JOIN #a")
        await harness.server.send(":alice!u@h JOIN #b")
        await harness.server.send(":alice!u@h JOIN #c")
        #expect(await waitUntil { harness.connection.channels.count == 3 })
        let before = harness.model.allBuffers.map(\.name)

        let item = AppModel.SidebarItem.channel(
            connection: harness.connection.id,
            channel: name("#c")
        )
        harness.model.bindings.bind(try #require(harness.model.binding(for: item)), to: 1)
        #expect(harness.model.allBuffers.map(\.name) == before)

        await harness.shutDown()
    }

    /// ⌘0 is the canvas's, and is not user-assignable.
    @Test("the canvas cannot be bound")
    func canvasIsNotBindable() {
        let model = temporaryModel()
        #expect(model.binding(for: .settingsAndDebug) == nil)
        #expect(model.buffer(for: .settingsAndDebug) == nil)
    }
}
