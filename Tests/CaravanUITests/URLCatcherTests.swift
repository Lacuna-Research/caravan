import AppKit
import CaravanTestSupport
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The URL catcher: what it collects, and where it says it came from.
@MainActor
@Suite("URL catcher")
struct URLCatcherTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    /// The load-bearing claim: the catcher reads the renderer's own answer rather than
    /// running a second detector over text that has already been scanned.
    @Test("links are read back off a rendered line")
    func readsLinksFromTheRenderedLine() throws {
        let catcher = URLCatcher()
        let renderer = LineRenderer()
        var fields = LineFields()
        fields.nick = "bob"
        fields.text = "see https://example.com/one and http://example.org/two"
        let line = renderer.line(kind: .message, fields: fields, now: epoch)

        catcher.record(line, network: "Libera", buffer: "#swift", date: epoch)
        #expect(
            catcher.entries.map(\.url.absoluteString).sorted()
                == ["http://example.org/two", "https://example.com/one"]
        )
        #expect(catcher.entries.allSatisfy { $0.network == "Libera" && $0.buffer == "#swift" })
    }

    @Test("a line with no links records nothing")
    func plainLineRecordsNothing() {
        let catcher = URLCatcher()
        let line = LineRenderer().line("nothing to see here", kind: .message, now: epoch)
        catcher.record(line, network: "Libera", buffer: "#swift", date: epoch)
        #expect(catcher.entries.isEmpty)
    }

    /// A bot reposting the same link every hour would otherwise be the whole window.
    @Test("a repeat moves to the front and takes the new time")
    func repeatsMoveRatherThanDuplicate() throws {
        let catcher = URLCatcher()
        let first = try url("https://example.com/a")
        let second = try url("https://example.com/b")
        catcher.record(first, network: "Libera", buffer: "#swift", date: epoch)
        catcher.record(second, network: "Libera", buffer: "#swift", date: epoch + 60)
        catcher.record(first, network: "Libera", buffer: "#swift", date: epoch + 120)

        #expect(catcher.entries.count == 2)
        #expect(catcher.entries.first?.url == first)
        #expect(catcher.entries.first?.date == epoch + 120)
    }

    /// "Where did I see this" is half of what the window is for, so the same link in two
    /// rooms is two rows.
    @Test("the same link in two buffers is two entries")
    func sameLinkInTwoBuffersIsTwoEntries() throws {
        let catcher = URLCatcher()
        let link = try url("https://example.com/a")
        catcher.record(link, network: "Libera", buffer: "#swift", date: epoch)
        catcher.record(link, network: "Libera", buffer: "#vapor", date: epoch)
        catcher.record(link, network: "OFTC", buffer: "#swift", date: epoch)
        #expect(catcher.entries.count == 3)
    }

    @Test("the oldest are dropped at the cap")
    func capsTheHistory() throws {
        let catcher = URLCatcher(cap: 3)
        for index in 0..<6 {
            catcher.record(
                try url("https://example.com/\(index)"),
                network: "Libera",
                buffer: "#swift",
                date: epoch
            )
        }
        #expect(catcher.entries.count == 3)
        #expect(
            catcher.entries.map(\.url.absoluteString)
                == ["https://example.com/5", "https://example.com/4", "https://example.com/3"]
        )
    }

    @Test("lowering the cap trims at once rather than at the next link")
    func loweringTheCapTrimsNow() throws {
        let catcher = URLCatcher(cap: 10)
        for index in 0..<6 {
            catcher.record(
                try url("https://example.com/\(index)"),
                network: "Libera",
                buffer: "#swift",
                date: epoch
            )
        }
        catcher.cap = 2
        #expect(catcher.entries.count == 2)
    }

    @Test("each scope filters to what it names")
    func scopes() throws {
        let catcher = URLCatcher()
        catcher.record(
            try url("https://a.example"),
            network: "Libera",
            buffer: "#swift",
            date: epoch
        )
        catcher.record(
            try url("https://b.example"),
            network: "Libera",
            buffer: "#vapor",
            date: epoch
        )
        catcher.record(try url("https://c.example"), network: "OFTC", buffer: "#swift", date: epoch)

        #expect(catcher.entries(in: .everywhere, network: "Libera", buffer: "#swift").count == 3)
        #expect(catcher.entries(in: .network, network: "Libera", buffer: "#swift").count == 2)
        #expect(catcher.entries(in: .buffer, network: "Libera", buffer: "#swift").count == 1)
        // A scope naming nothing catches nothing, rather than quietly showing everything.
        #expect(catcher.entries(in: .buffer, network: nil, buffer: nil).isEmpty)
    }

    /// End to end: a message off the wire, through the renderer, into the catcher, with
    /// the network and buffer the tree would name.
    @Test("a link in an arriving message is caught with its network and buffer")
    func catchesFromTheWire() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptCapabilityNegotiation(nick: "alice", offering: [])
        let model = temporaryModel()

        let connection = try #require(
            await model.connect(
                using: ConnectionSettings(
                    host: "127.0.0.1",
                    port: port,
                    useTLS: false,
                    nick: "alice",
                    realName: "Alice Example"
                )
            )
        )
        #expect(await waitUntil { connection.isConnected })

        await server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { connection.channels.count == 1 })
        await server.send(":bob!u@h PRIVMSG #swift :look at https://example.com/thing")
        #expect(await waitUntil { !model.urlCatcher.entries.isEmpty })

        let entry = try #require(model.urlCatcher.entries.first)
        #expect(entry.url.absoluteString == "https://example.com/thing")
        #expect(entry.buffer == "#swift")
        #expect(entry.network == connection.displayName)

        await model.disconnectAll()
        await server.stop()
    }
}
