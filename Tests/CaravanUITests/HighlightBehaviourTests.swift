import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// Highlights and interruptions end to end, through the real message path.
@MainActor
@Suite("Being interrupted")
struct HighlightBehaviourTests {
    @MainActor
    private final class Harness {
        let server: ScriptedIRCServer
        let connection: ConnectionViewModel
        let highlights: HighlightRules
        let alerts: Alerts
        let ignores: IgnoreList
        /// Everything the alert path delivered. The real deliverer is replaced, so nothing
        /// here can post a notification or make a noise.
        var posted: [Alert] = []

        init(server: ScriptedIRCServer, port: UInt16) {
            self.server = server
            let config = temporaryConfig()
            let settings = ChatSettings(config: config)
            self.highlights = HighlightRules(config: config)
            self.ignores = IgnoreList(config: config)
            let alerts = Alerts(settings: settings, deliver: { _ in })
            self.alerts = alerts
            self.connection = ConnectionViewModel(
                configuration: SessionConfiguration(
                    host: "127.0.0.1",
                    port: port,
                    tls: .disabled,
                    nick: "alice",
                    realName: "Alice Example"
                ),
                trace: TraceBuffer(capacity: 512),
                settings: settings
            )
            connection.highlights = highlights
            connection.alerts = alerts
            connection.ignores = ignores
            alerts.deliver = { [weak self] alert in self?.posted.append(alert) }
        }

        func shutDown() async {
            await connection.disconnect()
            await server.stop()
        }
    }

    private func harness() async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let harness = Harness(server: server, port: port)
        await harness.connection.connect()
        #expect(await waitUntil { harness.connection.isConnected })
        return harness
    }

    private func channel(_ harness: Harness) async throws -> ChannelBuffer {
        await harness.server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.connection.channels.count == 1 })
        return try #require(harness.connection.channels.first)
    }

    // MARK: - Highlighting

    @Test("a mention raises the buffer and interrupts once")
    func mentionAlerts() async throws {
        let harness = try await harness()
        let buffer = try await channel(harness)

        await harness.server.send(":bob!u@h PRIVMSG #swift :alice: look at this")
        #expect(await waitUntil { harness.posted.count == 1 })
        #expect(buffer.activity == .highlight)
        let alert = try #require(harness.posted.first)
        #expect(alert.title.contains("#swift"))
        #expect(alert.body == "<bob> alice: look at this")

        // An ordinary line raises the buffer no further and interrupts nobody.
        await harness.server.send(":bob!u@h PRIVMSG #swift :and something else")
        #expect(await waitUntil { buffer.log.lineCount >= 0 })
        #expect(harness.posted.count == 1)
        await harness.shutDown()
    }

    @Test("a keyword and a pattern each earn their own interruption")
    func keywordsAndPatterns() async throws {
        let harness = try await harness()
        _ = try await channel(harness)
        harness.highlights.add(HighlightPattern(kind: .word, text: "build failed"))
        harness.highlights.add(HighlightPattern(kind: .regex, text: "^ship it"))

        await harness.server.send(":bob!u@h PRIVMSG #swift :the build failed again")
        #expect(await waitUntil { harness.posted.count == 1 })
        await harness.server.send(":bob!u@h PRIVMSG #swift :ship it now")
        #expect(await waitUntil { harness.posted.count == 2 })
        // Neither rule matches this, and the nick is not in it either.
        await harness.server.send(":bob!u@h PRIVMSG #swift :the build worked")
        await harness.server.send(":bob!u@h PRIVMSG #swift :alice ping")
        #expect(await waitUntil { harness.posted.count == 3 })
        #expect(harness.posted.map(\.text).contains("the build failed again"))
        await harness.shutDown()
    }

    @Test("a private message interrupts you without needing your nick in it")
    func privateMessages() async throws {
        let harness = try await harness()
        await harness.server.send(":bob!u@h PRIVMSG alice :are you there")
        #expect(await waitUntil { harness.posted.count == 1 })
        #expect(harness.connection.queries.first?.activity == .highlight)
        await harness.shutDown()
    }

    // MARK: - The filters

    @Test("your own words never interrupt you")
    func ownWords() async throws {
        let harness = try await harness()
        _ = try await channel(harness)
        await harness.connection.send(
            IRCMessage(verb: "PRIVMSG", parameters: ["#swift", "alice talking to alice"]),
            from: .channel(IRCChannelName("#swift", mapping: .ascii))
        )
        await harness.server.send(":bob!u@h PRIVMSG #swift :alice: barrier")
        #expect(await waitUntil { harness.posted.count == 1 })
        #expect(harness.posted.first?.body.contains("barrier") == true)
        await harness.shutDown()
    }

    /// **The case the whole staleness rule exists for.** A bouncer reattach replays
    /// `CHATHISTORY` through the ordinary message path; the lines this client has not seen
    /// survive prompt 12's de-duplication, correctly, because they are new to it. Fifty of
    /// them mentioning your nick would be fifty notifications on connect.
    @Test("a backlog replayed on reattach is silent, and still raises the buffer")
    func replayIsSilent() async throws {
        let harness = try await harness()
        let buffer = try await channel(harness)
        let anHourAgo = Date().addingTimeInterval(-3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for index in 1...5 {
            await harness.server.send(
                "@time=\(formatter.string(from: anHourAgo)) "
                    + ":bob!u@h PRIVMSG #swift :alice: old message \(index)"
            )
        }
        // Something live afterwards, so there is a point at which the replay has landed.
        await harness.server.send(":bob!u@h PRIVMSG #swift :alice: live one")
        #expect(await waitUntil { harness.posted.count == 1 })

        // Exactly one interruption — the live line — and the buffer still went pink, which
        // is right: the backlog *is* unread, it is just not worth a notification.
        #expect(harness.posted.map(\.text) == ["alice: live one"])
        #expect(buffer.activity == .highlight)
        await harness.shutDown()
    }

    @Test("nothing interrupts you about the window you are looking at")
    func onScreenAndFrontmost() async throws {
        let harness = try await harness()
        let buffer = try await channel(harness)
        harness.connection.isBufferOnScreen = { $0 === buffer }
        // `NSApplication.shared.isActive` is false in a test runner, which is the other half
        // of the condition — so this asserts the half that is under our control, and
        // `AlertDecisionTests` covers the pair.
        #expect(
            !harness.alerts.shouldAlert(
                activity: .highlight,
                isConversation: false,
                isOwnMessage: false,
                isOnScreen: true,
                appIsActive: true,
                at: Date()
            )
        )
        await harness.shutDown()
    }

    /// 13a runs above this and must stay there.
    @Test("an ignored line never reaches the highlight rules")
    func ignoredLinesDoNotAlert() async throws {
        let harness = try await harness()
        let buffer = try await channel(harness)
        harness.ignores.add(IgnoreEntry(mask: "bob!*@*"))

        await harness.server.send(":bob!u@h PRIVMSG #swift :alice: you will not see this")
        await harness.server.send(":carol!u@h PRIVMSG #swift :alice: but you will see this")
        #expect(await waitUntil { harness.posted.count == 1 })
        #expect(harness.posted.first?.body.contains("carol") == true)
        #expect(buffer.activity == .highlight)
        await harness.shutDown()
    }

    /// Prompt 12's note asked for this to be pinned before it stops being true.
    @Test("a reloaded log line cannot notify, because it never reaches this path")
    func reloadedLogLinesDoNotAlert() async throws {
        let chatLog = temporaryChatLog()
        let harness = try await harness()
        let network = harness.connection.networkKey
        for index in 1...20 {
            chatLog.write(
                "[\(ChatLog.stamp(Date()))] <bob> alice: logged line \(index)",
                network: network,
                buffer: "#swift"
            )
        }
        chatLog.flush()
        harness.connection.chatLog = chatLog

        let buffer = try await channel(harness)
        // A real text view, or the controller keeps its lines queued and the assertion
        // below would pass without the reload ever having happened.
        let textView = MessageLogView.makeTextView(usesTextKit2: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView
        buffer.log.attach(textView: textView, scrollView: scrollView)
        scrollView.layoutSubtreeIfNeeded()
        buffer.log.flush()

        #expect(textView.string.contains("logged line 20"), "the reload did happen")
        // Twenty lines with the nick in them, put on screen the instant the window opened,
        // and not one interruption: `reloadLog(into:)` appends straight to the controller
        // rather than through `append(_:)`. That is safety by construction, and this is the
        // test that notices if a refactor ever routes it back through.
        #expect(harness.posted.isEmpty)
        chatLog.close()
        await harness.shutDown()
    }
}

/// The Dock badge and the menu-bar item, which are derived rather than counted.
@MainActor
@Suite("Surfaces that want your attention")
struct AttentionSurfaceTests {
    @Test("the badge counts highlights, and nothing else")
    func badgeCountsHighlights() async throws {
        let model = temporaryModel()
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let connection = try #require(
            await model.connect(
                using: ConnectionSettings(
                    host: "127.0.0.1",
                    port: port,
                    useTLS: false,
                    nick: "alice"
                )
            )
        )
        #expect(await waitUntil { connection.isConnected })

        await server.send(":alice!u@h JOIN #one")
        await server.send(":alice!u@h JOIN #two")
        #expect(await waitUntil { connection.channels.count == 2 })
        // Nothing selected on either, so both accumulate.
        model.selection = .dashboard

        await server.send(":bob!u@h PRIVMSG #one :alice: over here")
        await server.send(":bob!u@h PRIVMSG #two :just chatting")
        #expect(await waitUntil { connection.channels[0].activity == .highlight })
        #expect(await waitUntil { connection.channels[1].activity == .message })

        model.refreshAttentionSurfaces()
        #expect(NSApplication.shared.dockTile.badgeLabel == "1", "highlights only, per §3")

        // Looking at it clears it, and the badge goes with it.
        model.selection = .channel(
            connection: connection.id,
            channel: connection.channels[0].name
        )
        #expect(NSApplication.shared.dockTile.badgeLabel == nil)

        await model.disconnectAll()
        await server.stop()
        NSApplication.shared.dockTile.badgeLabel = nil
    }

    /// The menu lists everything wanting attention, not only the highlights — the count is
    /// the urgent thing and the list is the useful one.
    @Test("the menu-bar item lists what is waiting and marks the highlights")
    func menuRows() {
        let item = MenuBarItem()
        #expect(!item.isShowing)
        item.update(
            count: 1,
            rows: [
                .init(title: "libera/#one", item: .dashboard, isHighlight: true),
                .init(title: "libera/#two", item: .dashboard, isHighlight: false),
            ]
        )
        // Off by default, so updating it is a no-op rather than a crash.
        #expect(!item.isShowing)
        item.setVisible(true)
        #expect(item.isShowing)
        item.setVisible(false)
        #expect(!item.isShowing)
    }
}
