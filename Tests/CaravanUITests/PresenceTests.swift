import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The notify list as the user keeps it.
@MainActor
@Suite("The notify list")
struct NotifyListTests {
    @Test("nicks round-trip through the file, in order")
    func persistence() {
        let config = temporaryConfig()
        let first = NotifyList(config: config)
        first.add("bob")
        first.add("carol")
        #expect(config.string("notify.1") == "bob")
        #expect(config.string("notify.2") == "carol")

        let second = NotifyList(config: ConfigFile(url: config.url))
        #expect(second.nicks == ["bob", "carol"])
    }

    /// `Bob` and `bob` are one person on every server anybody uses.
    @Test("a duplicate is refused case-insensitively, but the spelling is the user's")
    func duplicates() {
        let list = NotifyList(config: temporaryConfig())
        #expect(list.add("Bob"))
        #expect(!list.add("bob"))
        #expect(list.nicks == ["Bob"], "stored as typed")
        #expect(list.contains("BOB"))
    }

    @Test("removing says whether there was anything to remove")
    func removing() {
        let list = NotifyList(config: temporaryConfig())
        list.add("bob")
        #expect(list.remove("BOB"))
        #expect(!list.remove("bob"))
        #expect(list.nicks.isEmpty)
    }

    @Test("blank input is not a nick")
    func blanks() {
        let list = NotifyList(config: temporaryConfig())
        #expect(!list.add("   "))
        #expect(list.nicks.isEmpty)
    }

    @Test("a change tells whoever is watching, so open connections re-issue MONITOR")
    func changeCallback() {
        let list = NotifyList(config: temporaryConfig())
        var calls = 0
        list.didChange = { calls += 1 }
        list.add("bob")
        list.remove("bob")
        list.remove("bob")
        #expect(calls == 2, "only a real change is a change")
    }

    @Test("entries load in numeric order, not alphabetical")
    func numericOrder() {
        let config = temporaryConfig()
        for index in 1...11 { config.set("nick\(index)", forKey: "notify.\(index)") }
        #expect(NotifyList(config: config).nicks.last == "nick11")
    }
}

/// A mutable idle reading a closure can capture.
@MainActor
private final class IdleClock {
    var seconds: TimeInterval = 0
}

/// Auto-away, and the summary that replaced the away log.
@MainActor
@Suite("Going away")
struct AwayTests {
    private func controller(minutes: Int) -> (AwayController, ChatSettings) {
        let settings = ChatSettings(config: temporaryConfig())
        settings.autoAwayMinutes = minutes
        return (AwayController(settings: settings), settings)
    }

    /// It speaks on the user's behalf, so it is opt-in.
    @Test("auto-away is off out of the box, and off means never")
    func offByDefault() {
        let settings = ChatSettings(config: temporaryConfig())
        #expect(settings.autoAwayMinutes == 0)

        let (away, _) = controller(minutes: 0)
        var calls: [String?] = []
        away.setAway = { calls.append($0) }
        away.idleSeconds = { 86_400 }
        away.tick()
        #expect(calls.isEmpty)
        #expect(!away.isAutoAway)
    }

    @Test("idling past the threshold goes away, and touching the keyboard comes back")
    func goesAwayAndReturns() {
        let (away, settings) = controller(minutes: 5)
        var calls: [String?] = []
        away.setAway = { calls.append($0) }
        // A box rather than a captured `var`: `idleSeconds` is a `@MainActor` closure and
        // the compiler will not let a local be mutated after capture.
        let clock = IdleClock()
        away.idleSeconds = { clock.seconds }

        away.tick()
        #expect(calls.isEmpty, "not idle yet")

        clock.seconds = 299
        away.tick()
        #expect(calls.isEmpty, "one second short")

        clock.seconds = 301
        away.tick()
        #expect(calls == [settings.awayMessage])
        #expect(away.isAutoAway)

        // Still idle: not a second announcement.
        away.tick()
        #expect(calls.count == 1)

        clock.seconds = 0
        away.tick()
        #expect(calls.count == 2)
        #expect(calls.last == .some(nil))
        #expect(!away.isAutoAway)
    }

    /// A client that cancelled a typed `/away` the moment somebody touched the mouse would
    /// be useless to anybody who sets one before a meeting.
    @Test("coming back to the keyboard does not undo an away you typed")
    func manualAwayIsLeftAlone() {
        let (away, _) = controller(minutes: 5)
        var calls: [String?] = []
        away.setAway = { calls.append($0) }
        away.idleSeconds = { 0 }

        away.noteManualAway()
        away.tick()
        #expect(calls.isEmpty)
        #expect(!away.isAutoAway)
    }

    @Test("turning it off while it has you away brings you back")
    func turningItOffReturns() {
        let (away, settings) = controller(minutes: 5)
        var calls: [String?] = []
        away.setAway = { calls.append($0) }
        away.idleSeconds = { 600 }
        away.tick()
        #expect(away.isAutoAway)

        settings.autoAwayMinutes = 0
        away.tick()
        #expect(calls.last == .some(nil))
        #expect(!away.isAutoAway)
    }

    /// One line rather than a second log viewer over what prompt 12 already shows.
    @Test("the return summary counts, and says nothing when nothing happened")
    func summary() {
        #expect(AwaySummary().sentence == nil)
        #expect(
            AwaySummary(highlights: 1).sentence == "While you were away: 1 highlight"
        )
        #expect(
            AwaySummary(highlights: 3, conversations: 1).sentence
                == "While you were away: 3 highlights, 1 private message"
        )
        #expect(
            AwaySummary(conversations: 2, busyBuffers: 4).sentence
                == "While you were away: 2 private messages, activity in 4"
        )
    }

    @Test("an away message with spaces at the ends survives the config file")
    func awayMessageEncoding() {
        let config = temporaryConfig()
        let settings = ChatSettings(config: config)
        settings.awayMessage = " back soon "
        #expect(config.string(ChatSettings.Key.awayMessage) == "_back_soon_")
        #expect(ChatSettings(config: ConfigFile(url: config.url)).awayMessage == " back soon ")
    }
}

/// Presence end to end, through a scripted server.
@MainActor
@Suite("Presence on the wire")
struct PresenceBehaviourTests {
    private final class Reader {
        var announced: [String] = []
    }

    private func harness(
        monitor: Bool
    ) async throws -> (ScriptedIRCServer, ConnectionViewModel) {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        let isupport =
            ["CASEMAPPING=ascii", "CHANTYPES=#", "PREFIX=(ov)@+"]
            + (monitor ? ["MONITOR=3"] : [])
        await server.scriptWelcome(nick: "alice", isupport: isupport)
        let connection = ConnectionViewModel(
            configuration: {
                var configuration = SessionConfiguration(
                    host: "127.0.0.1",
                    port: port,
                    tls: .disabled,
                    nick: "alice",
                    realName: "Alice Example"
                )
                // Long enough that this test can get its 730 in before the window closes,
                // short enough that waiting for the baseline is not most of the run. The
                // shipped value is five seconds.
                configuration.notifyBaselineGrace = .seconds(1)
                return configuration
            }(),
            trace: TraceBuffer(capacity: 512),
            settings: ChatSettings(config: temporaryConfig())
        )
        await connection.connect()
        #expect(await waitUntil { connection.isConnected })
        return (server, connection)
    }

    @Test("a server with MONITOR is told the list")
    func usesMonitor() async throws {
        let (server, connection) = try await harness(monitor: true)
        await connection.updateNotifyList(["bob", "carol"])
        #expect(
            await waitUntil {
                await server.receivedLines().contains { $0.hasPrefix("MONITOR + ") }
            }
        )
        let line = try #require(
            await server.receivedLines().first { $0.hasPrefix("MONITOR + ") }
        )
        #expect(line.contains("bob"))
        #expect(line.contains("carol"))
        #expect(await !server.receivedLines().contains { $0.hasPrefix("ISON") })
        await connection.disconnect()
        await server.stop()
    }

    /// The names past the limit would be indistinguishable from offline.
    @Test("a list longer than MONITOR= says so rather than silently truncating")
    func monitorLimit() async throws {
        let (server, connection) = try await harness(monitor: true)
        let reader = Reader()
        connection.presenceDidChange = { nick, _ in reader.announced.append(nick) }
        await connection.updateNotifyList(["a", "b", "c", "d"])

        let textView = MessageLogView.makeTextView(usesTextKit2: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView
        connection.log.attach(textView: textView, scrollView: scrollView)
        #expect(
            await waitUntil {
                connection.log.flush()
                return textView.string.contains("monitors at most 3")
            }
        )
        await connection.disconnect()
        await server.stop()
    }

    @Test("a server without MONITOR is polled with ISON instead")
    func fallsBackToISON() async throws {
        let (server, connection) = try await harness(monitor: false)
        await connection.updateNotifyList(["bob"])
        #expect(
            await waitUntil {
                await server.receivedLines().contains { $0.hasPrefix("ISON") }
            }
        )
        #expect(await !server.receivedLines().contains { $0.hasPrefix("MONITOR") })
        await connection.disconnect()
        await server.stop()
    }

    /// **The case the baseline exists for.** Connecting with two friends already online is
    /// one line, not two announcements of things that did not just happen.
    @Test("the first answer is one line, and only later changes announce")
    func baselineIsNotABurst() async throws {
        let (server, connection) = try await harness(monitor: true)
        let reader = Reader()
        connection.presenceDidChange = { nick, _ in reader.announced.append(nick) }
        let textView = MessageLogView.makeTextView(usesTextKit2: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView
        connection.log.attach(textView: textView, scrollView: scrollView)

        await connection.updateNotifyList(["bob", "carol"])
        #expect(
            await waitUntil {
                await server.receivedLines().contains { $0.hasPrefix("MONITOR + ") }
            }
        )
        // Both already online when we connected.
        await server.send(":server 730 alice :bob!u@h,carol!u@h")
        #expect(
            await waitUntil {
                connection.log.flush()
                return textView.string.contains("Notify")
            }
        )
        #expect(reader.announced.isEmpty, "a baseline is not a set of arrivals")
        #expect(textView.string.contains("bob"))
        #expect(textView.string.contains("carol"))

        // A change after the baseline is news.
        await server.send(":server 731 alice :bob")
        #expect(await waitUntil { reader.announced == ["bob"] })
        #expect(
            await waitUntil {
                connection.log.flush()
                return textView.string.contains("bob is offline")
            }
        )
        await connection.disconnect()
        await server.stop()
    }

    /// **The live-run defect.** The app hands over the notify list as soon as a connection
    /// is made, which is before registration finishes — `MONITOR` sent then is a line the
    /// server may ignore, and nothing retried it. The first acceptance run produced no
    /// `MONITOR` at all from a hand-written list.
    @Test("a list set before registration is issued once registration finishes")
    func listSetBeforeRegistrationStillReachesTheServer() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(
            nick: "alice",
            isupport: ["CASEMAPPING=ascii", "CHANTYPES=#", "PREFIX=(ov)@+", "MONITOR=3"]
        )
        let connection = ConnectionViewModel(
            configuration: {
                var configuration = SessionConfiguration(
                    host: "127.0.0.1",
                    port: port,
                    tls: .disabled,
                    nick: "alice",
                    realName: "Alice Example"
                )
                // Long enough that this test can get its 730 in before the window closes,
                // short enough that waiting for the baseline is not most of the run. The
                // shipped value is five seconds.
                configuration.notifyBaselineGrace = .seconds(1)
                return configuration
            }(),
            trace: TraceBuffer(capacity: 512),
            settings: ChatSettings(config: temporaryConfig())
        )
        // Before `connect()`, which is the order the app cannot avoid: the list exists at
        // launch and the connection does not.
        await connection.updateNotifyList(["bob"])
        await connection.connect()
        #expect(await waitUntil { connection.isConnected })

        #expect(
            await waitUntil {
                await server.receivedLines().contains { $0.hasPrefix("MONITOR + ") }
            }
        )
        // Cleared first, so a bouncer still holding last session's list does not end up
        // with everything twice.
        let lines = await server.receivedLines()
        let cleared = try #require(lines.firstIndex(of: "MONITOR C"))
        let added = try #require(lines.firstIndex { $0.hasPrefix("MONITOR + ") })
        #expect(cleared < added)
        await connection.disconnect()
        await server.stop()
    }

    @Test("our own away state follows the server, not the request")
    func awayState() async throws {
        let (server, connection) = try await harness(monitor: false)
        #expect(!connection.isAway)
        await connection.setAway("out to lunch")
        #expect(await waitUntil { await server.receivedLines().contains("AWAY :out to lunch") })
        // Still not away: the server has not said so.
        #expect(!connection.isAway)

        await server.send(":server 306 alice :You have been marked as away")
        #expect(await waitUntil { connection.isAway })
        await server.send(":server 305 alice :You are no longer marked away")
        #expect(await waitUntil { !connection.isAway })
        await connection.disconnect()
        await server.stop()
    }
}
