import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// Who is talking faster than a person talks.
@Suite("Detecting a flood")
struct FloodDetectorTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func nick(_ name: String) -> IRCNick { IRCNick(name, mapping: .ascii) }

    @Test("twenty in ten seconds trips; nineteen does not")
    func threshold() {
        var detector = FloodDetector(limit: 20, window: 10, duration: 60)
        for index in 0..<19 {
            let tripped = detector.record(nick: nick("bob"), at: start + Double(index) * 0.1)
            #expect(!tripped)
        }
        let twentieth = detector.record(nick: nick("bob"), at: start + 1.9)
        #expect(twentieth)
    }

    /// The caller's answer is to add an ignore; announcing it fifty times is not an answer.
    @Test("it trips once, not once per message afterwards")
    func tripsOnce() {
        var detector = FloodDetector(limit: 5, window: 10, duration: 60)
        for _ in 0..<4 { _ = detector.record(nick: nick("bob"), at: start) }
        let crossing = detector.record(nick: nick("bob"), at: start)
        let afterwards = detector.record(nick: nick("bob"), at: start)
        #expect(crossing)
        #expect(!afterwards, "the tail of the same flood")
    }

    /// Slow talking is not a flood however long you listen.
    @Test("messages older than the window fall out of it")
    func windowSlides() {
        var detector = FloodDetector(limit: 5, window: 10, duration: 60)
        for index in 0..<20 {
            let tripped = detector.record(nick: nick("bob"), at: start + Double(index) * 11)
            #expect(!tripped, "one every eleven seconds")
        }
    }

    /// **The property that makes a bouncer's replay harmless.** A hundred lines delivered in
    /// one second, stamped minutes apart, is a hundred messages over an hour.
    @Test("counting is by the line's timestamp, not by arrival")
    func countsByServerTime() {
        var detector = FloodDetector(limit: 20, window: 10, duration: 60)
        var tripped = false
        for index in 0..<200 {
            // Two hours of a busy channel, replayed in a single burst.
            tripped = detector.record(nick: nick("bob"), at: start + Double(index) * 36) || tripped
        }
        #expect(!tripped)
    }

    @Test("two people are two counts")
    func perNick() {
        var detector = FloodDetector(limit: 5, window: 10, duration: 60)
        for _ in 0..<4 {
            _ = detector.record(nick: nick("bob"), at: start)
            _ = detector.record(nick: nick("carol"), at: start)
        }
        let bob = detector.record(nick: nick("bob"), at: start)
        let carol = detector.record(nick: nick("carol"), at: start)
        #expect(bob)
        #expect(carol)
    }

    /// `Bob` and `bob` are one person on every server anybody uses.
    @Test("a nick is one person however it is spelled")
    func caseFolding() {
        var detector = FloodDetector(limit: 3, window: 10, duration: 60)
        _ = detector.record(nick: nick("Bob"), at: start)
        _ = detector.record(nick: nick("bob"), at: start)
        let third = detector.record(nick: nick("BOB"), at: start)
        #expect(third)
    }
}

/// The flood rules where they actually bite: on arriving traffic.
@MainActor
@Suite("Auto-ignoring a flood")
struct FloodBehaviourTests {
    private struct Harness {
        let server: ScriptedIRCServer
        let connection: ConnectionViewModel
        let ignores: IgnoreList
    }

    private func harness() async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let config = temporaryConfig()
        let connection = ConnectionViewModel(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: port,
                tls: .disabled,
                nick: "alice",
                realName: "Alice Example"
            ),
            trace: TraceBuffer(capacity: 512),
            settings: ChatSettings(config: config)
        )
        let ignores = IgnoreList(config: config)
        connection.ignores = ignores
        await connection.connect()
        #expect(await waitUntil { connection.isConnected })
        return Harness(server: server, connection: connection, ignores: ignores)
    }

    @Test("somebody flooding a channel is ignored, temporarily")
    func floodIsIgnored() async throws {
        let harness = try await harness()
        defer { Task { await harness.server.stop() } }

        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })

        for index in 0..<25 {
            await harness.server.send(":bob!~bob@home.example PRIVMSG #swift :spam \(index)")
        }
        #expect(await waitUntil { !harness.ignores.entries.isEmpty })

        let entry = try #require(harness.ignores.entries.first)
        #expect(entry.mask == "bob!*@*")
        #expect(entry.expires != nil, "temporary, so a mistake costs a minute")
    }

    /// **The prompt 15 note, answered by making it inapplicable.** Nothing a server sends is
    /// counted, so a `LIST` of thousands of lines cannot auto-ignore anybody — and the
    /// detector never has to ask whether a `LIST` is outstanding.
    @Test("a channel list of thousands ignores nobody")
    func channelListIsNotAFlood() async throws {
        let harness = try await harness()
        defer { Task { await harness.server.stop() } }

        for index in 0..<500 {
            await harness.server.send(":irc.example.org 322 alice #c\(index) 5 :topic")
        }
        await harness.server.send(":irc.example.org 323 alice :End of /LIST")
        #expect(await waitUntil { harness.connection.channelDirectory.listings.count == 500 })
        #expect(harness.ignores.entries.isEmpty)
    }

    @Test("with the setting off, nobody is ignored automatically")
    func canBeTurnedOff() async throws {
        let harness = try await harness()
        defer { Task { await harness.server.stop() } }
        harness.connection.settings.autoIgnoresFloods = false

        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        for index in 0..<40 {
            await harness.server.send(":bob!~bob@home.example PRIVMSG #swift :spam \(index)")
        }
        // A barrier that is not itself a flood: once it lands, the forty are long past.
        let textView = MessageLogView.makeTextView(usesTextKit2: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView
        harness.connection.log.attach(textView: textView, scrollView: scrollView)
        scrollView.layoutSubtreeIfNeeded()
        await harness.server.send(":irc.example.org NOTICE alice :barrier")
        #expect(
            await waitUntil {
                harness.connection.log.flush()
                return textView.string.contains("barrier")
            }
        )
        #expect(harness.ignores.entries.isEmpty)
    }
}
