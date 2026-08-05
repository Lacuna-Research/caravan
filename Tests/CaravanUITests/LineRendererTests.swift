import AppKit
import IRCProtocol
import IRCSession
import IRCTransport
import Testing

@testable import CaravanUI

@MainActor
@Suite("Line rendering")
struct LineRendererTests {
    private func text(_ event: IRCEvent, ownNick: String? = "alice") -> String? {
        LineRenderer.line(for: event, ownNick: ownNick).map { String($0.characters) }
    }

    private func user(_ nick: String) -> IRCSource {
        .user(nick: nick, user: "u", host: "example.org")
    }

    private var capabilities: ServerCapabilities {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: ["CASEMAPPING=ascii", "CHANTYPES=#"])
        return capabilities
    }

    @Test("a channel message uses the mIRC nick form")
    func message() {
        let event = IRCEvent.message(
            target: Target("#swift", capabilities: capabilities),
            sender: user("bob"),
            text: "hello there",
            kind: .privmsg,
            isAction: false
        )
        #expect(text(event) == "<bob> hello there")
    }

    @Test("a notice is visibly not a message")
    func notice() {
        let event = IRCEvent.message(
            target: Target("#swift", capabilities: capabilities),
            sender: user("bob"),
            text: "heads up",
            kind: .notice,
            isAction: false
        )
        #expect(text(event) == "-bob- heads up")
    }

    @Test("an action renders as a third-person line")
    func action() {
        let event = IRCEvent.message(
            target: Target("#swift", capabilities: capabilities),
            sender: user("bob"),
            text: "waves",
            kind: .privmsg,
            isAction: true
        )
        #expect(text(event) == "* bob waves")
    }

    /// The MOTD arrives as numerics, and every one of them repeats our own nick.
    @Test("a numeric drops the leading copy of our own nick")
    func numericDropsOwnNick() {
        let event = IRCEvent.numeric(code: 372, parameters: ["alice", "- welcome to the network"])
        #expect(text(event) == "- welcome to the network")
        // Not ours: left alone, since it is then part of the message.
        #expect(text(event, ownNick: "carol") == "alice - welcome to the network")
    }

    /// `.raw` reaching the window would double every line in it.
    @Test("raw events do not render")
    func rawDoesNotRender() throws {
        let message = try #require(IRCMessage(line: ":irc.example.org 372 alice :text"))
        #expect(text(.raw(message)) == nil)
    }

    @Test("membership events read like mIRC")
    func membership() {
        #expect(
            text(.joined(channel: IRCChannelName("#swift"), who: user("bob")))
                == "*** Joins: bob (u@example.org) #swift"
        )
        #expect(
            text(.parted(channel: IRCChannelName("#swift"), who: user("bob"), reason: "bye"))
                == "*** Parts: bob #swift (bye)"
        )
        #expect(text(.quit(who: user("bob"), reason: nil)) == "*** Quits: bob")
        #expect(
            text(.nickChanged(who: user("bob"), newNick: "robert"))
                == "*** bob is now known as robert"
        )
    }

    @Test("topics distinguish a change, a standing topic and no topic at all")
    func topics() {
        let channel = IRCChannelName("#swift")
        #expect(
            text(.topicChanged(channel: channel, who: user("bob"), topic: "Swift talk"))
                == "*** bob changed #swift: Swift talk"
        )
        #expect(
            text(.topicChanged(channel: channel, who: nil, topic: "Swift talk"))
                == "*** Topic for #swift: Swift talk"
        )
        // 331, and a `TOPIC` that cleared one. Rendering an empty string after a colon
        // says "there is no topic" badly.
        #expect(
            text(.topicChanged(channel: channel, who: nil, topic: ""))
                == "*** No topic is set for #swift"
        )
        #expect(
            text(.topicChanged(channel: channel, who: user("bob"), topic: ""))
                == "*** bob cleared the topic for #swift"
        )
    }

    /// A mode line reads the way the server writes it: signs collapsed, arguments after.
    @Test("mode changes render in their wire shape")
    func modes() {
        let changes = [
            ModeChange(isSet: true, mode: "o", argument: "carol"),
            ModeChange(isSet: true, mode: "n"),
            ModeChange(isSet: false, mode: "v", argument: "dave"),
        ]
        #expect(
            text(
                .modeChanged(
                    target: Target("#swift", capabilities: capabilities),
                    who: user("bob"),
                    changes: changes
                )
            ) == "*** bob sets mode: +on-v carol dave on #swift"
        )
        #expect(
            text(
                .channelModes(
                    channel: IRCChannelName("#swift", mapping: .ascii),
                    changes: [
                        ModeChange(isSet: true, mode: "n"),
                        ModeChange(isSet: true, mode: "t"),
                    ]
                )
            ) == "*** Channel modes for #swift: +nt"
        )
    }

    /// A join failure is something the user can act on, so it reads as our error rather
    /// than as another server numeric.
    @Test("a join failure names the channel and says why")
    func joinFailure() {
        #expect(
            text(
                .joinFailed(
                    channel: IRCChannelName("#swift"),
                    reason: .badKey,
                    text: "Cannot join channel (+k)"
                )
            ) == "*** Cannot join #swift: Cannot join channel (+k)"
        )
        // A server that sent no text still gets a usable sentence.
        #expect(
            text(.joinFailed(channel: IRCChannelName("#swift"), reason: .inviteOnly, text: ""))
                == "*** Cannot join #swift: the channel is invite only"
        )
    }

    /// State, not a thing that happened. The nick list and the tree are where these land.
    @Test("channel snapshots and closures render no line")
    func snapshotsAreSilent() {
        #expect(text(.channelChanged(Channel(name: IRCChannelName("#swift")))) == nil)
        #expect(text(.channelClosed(IRCChannelName("#swift"))) == nil)
        #expect(text(.namesReply(channel: IRCChannelName("#swift"), names: ["bob"])) == nil)
    }

    /// The carry-forward from prompt 5: a status line saying only "disconnected" throws
    /// away the one thing the user wants to know.
    @Test(
        "every disconnect reason says why",
        arguments: [
            (DisconnectReason.userInitiated, "Disconnected"),
            (.serverError("Closing link: banned"), "Closing link: banned"),
            (.registrationFailed("no nickname left"), "no nickname left"),
            (.timedOut, "stopped responding"),
            (.connectTimedOut, "timed out"),
            (.transportFailed(.closedByPeer), "closed by peer"),
        ]
    )
    func disconnectReasonsAreExplained(reason: DisconnectReason, expected: String) {
        let rendered = LineRenderer.statusLine(for: .disconnected(reason: reason))
        #expect(rendered?.contains(expected) == true)
    }

    @Test("a connection that never started says nothing")
    func notStartedIsSilent() {
        #expect(LineRenderer.statusLine(for: .disconnected(reason: .notStarted)) == nil)
    }

    @Test("reconnecting reports the attempt and the wait")
    func reconnecting() {
        let rendered = LineRenderer.statusLine(
            for: .reconnecting(attempt: 3, nextAttemptIn: .milliseconds(1500))
        )
        #expect(rendered == "*** Reconnecting (attempt 3) in 1.5s")
    }

    @Test("URLs in a line become links")
    func detectsLinks() {
        let line = LineRenderer.line("see https://example.org/page for details")
        let links = line.runs.compactMap(\.link)
        #expect(links.map(\.absoluteString) == ["https://example.org/page"])
    }

    @Test("a line with no URL is not scanned for one")
    func noLinks() {
        let line = LineRenderer.line("nothing to see here")
        #expect(line.runs.allSatisfy { $0.link == nil })
    }
}
