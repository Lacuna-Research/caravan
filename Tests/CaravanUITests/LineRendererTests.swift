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
