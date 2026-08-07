import CaravanTestSupport
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The ranking the ⌘K palette lives or dies by. Pure, so it is arithmetic rather than
/// something to eyeball.
@Suite("Fuzzy matching")
struct FuzzyMatchTests {
    private func ref(
        _ network: String,
        _ name: String,
        activity: BufferActivity = .none,
        isStatus: Bool = false
    ) -> BufferRef {
        BufferRef(
            item: .status(UUID()),
            connectionID: UUID(),
            networkName: network,
            name: name,
            activity: activity,
            isStatus: isStatus
        )
    }

    @Test("a subsequence matches; anything else does not")
    func subsequence() {
        #expect(FuzzyMatch.score("swift", in: "#swift") != nil)
        #expect(FuzzyMatch.score("swt", in: "#swift") != nil)
        #expect(FuzzyMatch.score("tfiws", in: "#swift") == nil)
        #expect(FuzzyMatch.score("swiftx", in: "#swift") == nil)
    }

    /// An empty query lists everything, which is what fills the palette before you type.
    @Test("an empty query matches everything equally")
    func emptyQuery() {
        #expect(FuzzyMatch.score("", in: "#swift") == 0)
        #expect(FuzzyMatch.score("", in: "anything at all") == 0)
    }

    /// The claim the palette rests on: typing a couple of characters puts the obvious
    /// answer first.
    @Test("consecutive and word-start matches win")
    func ranking() throws {
        let buffers = [
            ref("Libera.Chat", "#news-worldwide"),
            ref("Libera.Chat", "#swift"),
            ref("Libera.Chat", "#some-wild-thing"),
        ]
        let ranked = FuzzyMatch.rank(buffers, query: "swi")
        #expect(ranked.first?.name == "#swift")
    }

    @Test("a shorter name beats a longer one holding the same match")
    func shorterWins() {
        let ranked = FuzzyMatch.rank(
            [ref("N", "#golang-newcomers"), ref("N", "#go")],
            query: "go"
        )
        #expect(ranked.first?.name == "#go")
    }

    /// The only way to tell two identically named channels apart in a flat list (§12).
    @Test("the network is part of what is matched")
    func networkNarrows() throws {
        let buffers = [ref("Libera.Chat", "#music"), ref("OFTC", "#music")]
        #expect(FuzzyMatch.rank(buffers, query: "oftc").first?.networkName == "OFTC")
        #expect(FuzzyMatch.rank(buffers, query: "libera").first?.networkName == "Libera.Chat")
    }

    /// A list that reshuffles between keystrokes is one where Enter lands somewhere you
    /// did not look at.
    @Test("ties break stably, by name")
    func stableTies() {
        let buffers = [ref("N", "#bbb"), ref("N", "#aaa"), ref("N", "#ccc")]
        let first = FuzzyMatch.rank(buffers, query: "#")
        let second = FuzzyMatch.rank(buffers.reversed(), query: "#")
        #expect(first.map(\.name) == second.map(\.name))
    }

    /// Found by the live run: the palette put `##caravan-nav-10` above `##caravan-nav-2`
    /// before anything was typed, because with every score equal it fell back to
    /// shortest-then-alphabetical. A palette you have not typed into should look like the
    /// tree you were just looking at.
    @Test("an empty query keeps the tree's order")
    func emptyQueryKeepsOrder() {
        let buffers = [ref("N", "#zulu"), ref("N", "#alpha-longer-name"), ref("N", "#mike")]
        #expect(FuzzyMatch.rank(buffers, query: "").map(\.name) == buffers.map(\.name))
        #expect(FuzzyMatch.rank(buffers, query: "   ").map(\.name) == buffers.map(\.name))
    }

    /// Found by the live run: `nav-11` matched one channel on each of two networks and
    /// landed on the quiet one. Two buffers matching equally well are not equally
    /// interesting.
    @Test("an equal match with more activity ranks higher")
    func activityBreaksTies() {
        let quiet = ref("OFTC", "#dup", activity: .none)
        let loud = ref("OFTC", "#dup", activity: .highlight)
        #expect(FuzzyMatch.rank([quiet, loud], query: "dup").first?.activity == .highlight)
        #expect(FuzzyMatch.rank([loud, quiet], query: "dup").first?.activity == .highlight)
    }

    /// Found by the live run: reaching for `libera nav-11` to pick one of two identically
    /// named channels found nothing, because the candidate has a slash where the space is.
    @Test("a space in the query means “and then, later”")
    func spacesSeparate() {
        let libera = ref("Libera.Chat", "##caravan-nav-11")
        let oftc = ref("OFTC", "#caravan-nav-11")
        let ranked = FuzzyMatch.rank([oftc, libera], query: "libera nav-11")
        #expect(ranked.map(\.networkName) == ["Libera.Chat"])
    }
}

/// The flat list, the two "go to something" keys, and Ctrl+Tab.
@MainActor
@Suite("Buffer navigation")
struct BufferNavigationTests {
    private struct Network {
        let server: ScriptedIRCServer
        let port: UInt16
    }

    private func network() async throws -> Network {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
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

    private func name(_ raw: String) -> IRCChannelName { IRCChannelName(raw, mapping: .ascii) }

    /// Status, then channels in join order, then conversations (§12) — the tree's own
    /// order, because three readers must not disagree about where `#swift` sits.
    @Test("the flat list is the tree's order, across every network")
    func flatListOrder() async throws {
        let first = try await network()
        let second = try await network()
        let model = temporaryModel()
        await model.connect(using: settings(port: first.port))
        await model.connect(using: settings(port: second.port))
        #expect(await waitUntil { model.connections.allSatisfy(\.isConnected) })

        await first.server.send(":alice!u@h JOIN #swift")
        await first.server.send(":bob!u@h PRIVMSG alice :hi")
        await first.server.send(":alice!u@h JOIN #vapor")
        await second.server.send(":alice!u@h JOIN #oftc-chan")
        #expect(
            await waitUntil {
                model.connections[0].channels.count == 2
                    && model.connections[0].queries.count == 1
                    && model.connections[1].channels.count == 1
            }
        )

        // Channels in join order before the conversation, even though the conversation
        // opened between the two joins.
        #expect(
            model.allBuffers.map(\.name) == [
                model.connections[0].displayName, "#swift", "#vapor", "bob",
                model.connections[1].displayName, "#oftc-chan",
            ]
        )

        await model.disconnectAll()
        await first.server.stop()
        await second.server.stop()
    }

    /// Starting *after* the current buffer is what makes repeated presses sweep the tree
    /// rather than bounce between the first two matches.
    @Test("next-unread sweeps forward and wraps")
    func nextUnread() async throws {
        let net = try await network()
        let model = temporaryModel()
        await model.connect(using: settings(port: net.port))
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        let connection = try #require(model.activeConnection)

        await net.server.send(":alice!u@h JOIN #a")
        await net.server.send(":alice!u@h JOIN #b")
        #expect(await waitUntil { connection.channels.count == 2 })
        // Look at the status window, and clear what the joins raised.
        model.selection = .status(connection.id)
        for entry in connection.buffers { entry.buffer.activity = .none }

        await net.server.send(":bob!u@h PRIVMSG #a :one")
        await net.server.send(":bob!u@h PRIVMSG #b :two")
        #expect(
            await waitUntil {
                connection.buffer(named: name("#a"))?.activity == .message
                    && connection.buffer(named: name("#b"))?.activity == .message
            }
        )

        model.selectNextUnread()
        #expect(model.selection == .channel(connection: connection.id, channel: name("#a")))
        model.selectNextUnread()
        #expect(model.selection == .channel(connection: connection.id, channel: name("#b")))
        // Nothing left unread — #a and #b were both cleared by being selected.
        #expect(!model.hasUnreadBuffer)

        await model.disconnectAll()
        await net.server.stop()
    }

    /// On a busy network unread is noise and highlights are not. The whole reason §9 asks
    /// for two bindings rather than one.
    @Test("next-highlight skips buffers that merely have traffic")
    func nextHighlight() async throws {
        let net = try await network()
        let model = temporaryModel()
        await model.connect(using: settings(port: net.port))
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        let connection = try #require(model.activeConnection)

        await net.server.send(":alice!u@h JOIN #noisy")
        await net.server.send(":alice!u@h JOIN #quiet")
        #expect(await waitUntil { connection.channels.count == 2 })
        model.selection = .status(connection.id)
        for entry in connection.buffers { entry.buffer.activity = .none }

        await net.server.send(":bob!u@h PRIVMSG #noisy :chatter")
        await net.server.send(":bob!u@h PRIVMSG #quiet :alice: over here")
        #expect(
            await waitUntil {
                connection.buffer(named: name("#quiet"))?.activity == .highlight
            }
        )

        model.selectNextHighlight()
        #expect(model.selection == .channel(connection: connection.id, channel: name("#quiet")))
        #expect(!model.hasHighlightedBuffer)
        // The noisy one is still unread, which is the distinction under test.
        #expect(model.hasUnreadBuffer)

        await model.disconnectAll()
        await net.server.stop()
    }

    /// §9: jumping to a buffer inside a collapsed group and leaving the group shut would
    /// be a jump to somewhere invisible.
    @Test("reaching a hidden buffer expands its network")
    func revealExpands() async throws {
        let net = try await network()
        let model = temporaryModel()
        await model.connect(using: settings(port: net.port))
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        let connection = try #require(model.activeConnection)

        await net.server.send(":alice!u@h JOIN #hidden")
        #expect(await waitUntil { connection.channels.count == 1 })
        model.selection = .status(connection.id)
        connection.isExpanded = false
        for entry in connection.buffers { entry.buffer.activity = .none }

        await net.server.send(":bob!u@h PRIVMSG #hidden :hello")
        #expect(await waitUntil { model.hasUnreadBuffer })
        model.selectNextUnread()

        #expect(connection.isExpanded)
        #expect(model.selection == .channel(connection: connection.id, channel: name("#hidden")))

        await model.disconnectAll()
        await net.server.stop()
    }

    /// The Windows Alt-Tab model: tap to toggle the last two.
    @Test("Ctrl+Tab toggles between the last two buffers")
    func mruToggle() async throws {
        let net = try await network()
        let model = temporaryModel()
        await model.connect(using: settings(port: net.port))
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        let connection = try #require(model.activeConnection)

        await net.server.send(":alice!u@h JOIN #a")
        await net.server.send(":alice!u@h JOIN #b")
        #expect(await waitUntil { connection.channels.count == 2 })

        let status = AppModel.SidebarItem.status(connection.id)
        let a = AppModel.SidebarItem.channel(connection: connection.id, channel: name("#a"))
        let b = AppModel.SidebarItem.channel(connection: connection.id, channel: name("#b"))
        model.selection = status
        model.selection = a
        model.selection = b

        model.cycleMRU()
        #expect(model.selection == a)
        model.endMRUCycle()

        // And back again: the commit put `a` at the front, so the next tap returns to `b`.
        model.cycleMRU()
        #expect(model.selection == b)
        model.endMRUCycle()

        await model.disconnectAll()
        await net.server.stop()
    }

    /// The subtlety that makes "hold and keep tapping" work: committing each step would
    /// reshuffle the list under the walk, so the second tap would bring you back where you
    /// started and walking further would be impossible.
    @Test("holding the modifier walks further back without reshuffling")
    func mruWalk() async throws {
        let net = try await network()
        let model = temporaryModel()
        await model.connect(using: settings(port: net.port))
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        let connection = try #require(model.activeConnection)

        await net.server.send(":alice!u@h JOIN #a")
        await net.server.send(":alice!u@h JOIN #b")
        await net.server.send(":alice!u@h JOIN #c")
        #expect(await waitUntil { connection.channels.count == 3 })

        let status = AppModel.SidebarItem.status(connection.id)
        let a = AppModel.SidebarItem.channel(connection: connection.id, channel: name("#a"))
        let b = AppModel.SidebarItem.channel(connection: connection.id, channel: name("#b"))
        let c = AppModel.SidebarItem.channel(connection: connection.id, channel: name("#c"))
        for item in [status, a, b, c] { model.selection = item }

        // One press, then another without releasing: c → b → a, not c → b → c.
        model.cycleMRU()
        #expect(model.selection == b)
        model.cycleMRU()
        #expect(model.selection == a)
        model.cycleMRU()
        #expect(model.selection == status)
        model.endMRUCycle()

        // The commit put `status` at the front, and `c` — where the walk began — second.
        model.cycleMRU()
        #expect(model.selection == c)
        model.endMRUCycle()

        await model.disconnectAll()
        await net.server.stop()
    }

    @Test("a closed buffer drops out of the MRU order")
    func mruDropsClosedBuffers() async throws {
        let net = try await network()
        let model = temporaryModel()
        await model.connect(using: settings(port: net.port))
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        let connection = try #require(model.activeConnection)

        await net.server.send(":bob!u@h PRIVMSG alice :hi")
        #expect(await waitUntil { connection.queries.count == 1 })
        let bob = AppModel.SidebarItem.query(
            connection: connection.id,
            nick: IRCNick("bob", mapping: .ascii)
        )
        model.selection = .status(connection.id)
        model.selection = bob
        model.selection = .status(connection.id)

        connection.closeQuery(IRCNick("bob", mapping: .ascii))
        model.cycleMRU()
        #expect(model.selection != bob)
        model.endMRUCycle()

        await model.disconnectAll()
        await net.server.stop()
    }
}
