import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The collector between twenty-two thousand arriving rows and one table.
@MainActor
@Suite("The channel directory")
struct ChannelDirectoryTests {
    private func listing(_ name: String, members: Int = 1, topic: String = "") -> ChannelListing {
        ChannelListing(name: IRCChannelName(name, mapping: .ascii), members: members, topic: topic)
    }

    /// **The property the whole surface rests on.** Rows arriving must not each be a
    /// published change; if they were, a `LIST` against Libera would be twenty-two thousand
    /// view invalidations and the search field would stop taking keystrokes.
    @Test("thousands of arrivals publish once, at the end")
    func coalescing() {
        let directory = ChannelDirectory(flushInterval: .seconds(60))
        directory.beginCollecting()
        for index in 0..<22_000 {
            directory.add(listing("#c\(index)"))
        }
        // Nothing published yet: the deadline has not come and the list has not ended.
        #expect(directory.listings.isEmpty)
        #expect(directory.arrivedCount == 22_000)

        directory.endCollecting()
        #expect(directory.listings.count == 22_000)
        #expect(directory.publishCount == 1)
        #expect(!directory.isCollecting)
    }

    @Test("the deadline publishes while rows are still arriving")
    func periodicFlush() async throws {
        let directory = ChannelDirectory(flushInterval: .milliseconds(20))
        directory.beginCollecting()
        directory.add(listing("#early"))
        #expect(await waitUntil { directory.listings.count == 1 })
        #expect(directory.isCollecting, "a flush is not an ending")

        directory.add(listing("#later"))
        directory.endCollecting()
        #expect(directory.listings.count == 2)
    }

    /// A re-list takes ten seconds against a large network; blanking the table for them
    /// loses whatever the user was reading, often the row they were about to click.
    @Test("the previous list stays on screen until the first new row arrives")
    func rowsSurviveUntilReplaced() {
        let directory = ChannelDirectory(flushInterval: .seconds(60))
        directory.beginCollecting()
        directory.add(listing("#old"))
        directory.endCollecting()
        #expect(directory.listings.map(\.name.raw) == ["#old"])

        directory.beginCollecting()
        #expect(directory.listings.map(\.name.raw) == ["#old"], "still readable")
        directory.add(listing("#new"))
        directory.endCollecting()
        #expect(directory.listings.map(\.name.raw) == ["#new"])
    }

    /// `LIST` has no cancel in the protocol. Stopping stops *collecting*; the rest of the
    /// reply is still coming, and it must not quietly reopen the collection.
    @Test("stopping drops what the server keeps sending")
    func stopping() {
        let directory = ChannelDirectory(flushInterval: .seconds(60))
        directory.beginCollecting()
        directory.add(listing("#kept"))
        directory.stopCollecting()
        #expect(directory.listings.map(\.name.raw) == ["#kept"])

        directory.add(listing("#arrivedAnyway"))
        #expect(directory.listings.map(\.name.raw) == ["#kept"])

        // Until the server says it is done, after which a fresh `LIST` collects normally.
        directory.endCollecting()
        directory.add(listing("#next"))
        directory.endCollecting()
        #expect(directory.listings.map(\.name.raw) == ["#next"])
    }

    /// A `LIST` sent by hand through `/quote`, or replayed by a bouncer at attach, never
    /// went through `beginCollecting()` — and must not be thrown away for it.
    @Test("an unrequested list is collected anyway")
    func unrequestedList() {
        let directory = ChannelDirectory(flushInterval: .seconds(60))
        directory.add(listing("#surprise"))
        directory.endCollecting()
        #expect(directory.listings.map(\.name.raw) == ["#surprise"])
    }

    @Test("the topic loses its formatting codes on the way in")
    func topicStripping() {
        let entry = listing("#swift", topic: "\u{03}04red\u{03} and \u{02}bold\u{02}")
        #expect(entry.topic == "red and bold")
    }
}

/// The fields above the table.
@Suite("Filtering the channel list")
struct ChannelListQueryTests {
    private let rows = [
        // Deliberately a topic that does *not* contain the name, so a topic-only search can
        // be told apart from a name-only one.
        ChannelListing(
            name: IRCChannelName("#swift", mapping: .ascii),
            members: 214,
            topic: "Language talk"
        ),
        ChannelListing(
            name: IRCChannelName("#rust", mapping: .ascii),
            members: 900,
            topic: "Systems"
        ),
        ChannelListing(
            name: IRCChannelName("#quiet", mapping: .ascii),
            members: 2,
            topic: "swift boats"
        ),
    ]

    private func names(_ query: ChannelListQuery) -> [String] {
        query.apply(to: rows).map(\.name.raw)
    }

    @Test("no filter keeps everything, and says so without a pass")
    func everything() {
        let query = ChannelListQuery()
        #expect(query.isEverything)
        #expect(names(query) == ["#swift", "#rust", "#quiet"])
    }

    @Test("member bounds are inclusive, and an absent bound is not zero")
    func memberBounds() {
        var query = ChannelListQuery()
        query.minimumMembers = 214
        #expect(names(query) == ["#swift", "#rust"])

        query.maximumMembers = 214
        #expect(names(query) == ["#swift"])

        // The distinction that matters: no maximum, rather than a maximum of zero.
        query.minimumMembers = nil
        query.maximumMembers = nil
        #expect(names(query).count == 3)
    }

    @Test("search matches names, topics, or whichever half is enabled")
    func searching() {
        var query = ChannelListQuery()
        query.text = "swift"
        #expect(names(query) == ["#swift", "#quiet"], "the name and the other's topic")

        query.searchesTopics = false
        #expect(names(query) == ["#swift"])

        query.searchesNames = false
        query.searchesTopics = true
        #expect(names(query) == ["#quiet"])
    }

    @Test("search is case-insensitive on both sides")
    func caseInsensitivity() {
        var query = ChannelListQuery()
        query.text = "SYSTEMS"
        #expect(names(query) == ["#rust"])
        query.text = "#RUST"
        #expect(names(query) == ["#rust"])
    }
}

/// The regression that only a real reply shows: what `/list` does to the status window.
@MainActor
@Suite("A channel list, end to end")
struct ChannelListBehaviourTests {
    private func harness() async throws -> (ScriptedIRCServer, ConnectionViewModel) {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let connection = ConnectionViewModel(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: port,
                tls: .disabled,
                nick: "alice",
                realName: "Alice Example"
            ),
            trace: TraceBuffer(capacity: 512),
            settings: ChatSettings(config: temporaryConfig())
        )
        await connection.connect()
        #expect(await waitUntil { connection.isConnected })
        return (server, connection)
    }

    /// **Found in the live run, and invisible to every other kind of test.** Opening the
    /// canvas makes the selection a canvas, and `activeConnection` reads the selection — so
    /// a network decided *after* the move is always `nil`, and a connected client opened a
    /// list that said "connect to a network" with Get List greyed out.
    @Test("opening the canvas keeps the network the tree was on")
    func openingKeepsItsNetwork() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: [])
        defer { Task { await server.stop() } }

        let model = temporaryModel()
        let connection = await model.connect(
            using: ConnectionSettings(
                host: "127.0.0.1",
                port: port,
                useTLS: false,
                nick: "alice",
                realName: "Alice Example"
            )
        )
        #expect(await waitUntil { connection?.isConnected == true })

        model.showChannelList()
        #expect(model.selection == .channelList)
        #expect(model.activeConnection == nil, "a canvas has no network of its own")
        #expect(model.channelListConnection === connection, "but the list remembers one")
    }

    /// **The bug this prompt starts from.** Before 322 was typed, every row of a `LIST`
    /// rendered into the status window — twenty-two thousand lines on Libera. A few hundred
    /// here proves the same thing and runs in a second.
    @Test("the rows land in the directory and nowhere near the status window")
    func listDoesNotReachTheStatusWindow() async throws {
        let (server, connection) = try await harness()
        defer { Task { await server.stop() } }

        let textView = MessageLogView.makeTextView(usesTextKit2: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView
        connection.log.attach(textView: textView, scrollView: scrollView)
        scrollView.layoutSubtreeIfNeeded()

        await server.send(":irc.example.org 321 alice Channel :Users  Name")
        for index in 0..<500 {
            await server.send(":irc.example.org 322 alice #c\(index) \(index) :topic \(index)")
        }
        await server.send(":irc.example.org 323 alice :End of /LIST")

        #expect(await waitUntil { connection.channelDirectory.listings.count == 500 })

        connection.log.flush()
        let text = textView.string
        #expect(!text.contains("#c1 "), "no entry may be drawn")
        #expect(!text.contains("topic 42"))
        // 321 is not suppressed — it is an ordinary numeric, and one line is not a flood.
        #expect(text.contains("End of /LIST") == false, "323 is consumed too")

        let listings = connection.channelDirectory.listings
        #expect(listings.first?.name.raw == "#c0")
        #expect(listings.last?.members == 499)
    }
}
