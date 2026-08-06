import AppKit
import Foundation
import IRCProtocol
import IRCSession
import IRCTransport
import Testing

@testable import CaravanUI

@MainActor
@Suite("Line rendering")
struct LineRendererTests {
    /// Timestamps off unless a test is about them: every other assertion here is about
    /// the wording, and a clock in the expected string makes it about the clock.
    private let renderer = LineRenderer(timestampFormat: "")

    private func text(_ event: IRCEvent, ownNick: String? = "alice", prefix: Character? = nil)
        -> String?
    {
        renderer.line(for: event, context: RenderContext(ownNick: ownNick, senderPrefix: prefix))
            .map { String($0.characters) }
    }

    private func user(_ nick: String) -> IRCSource {
        .user(nick: nick, user: "u", host: "example.org")
    }

    private var capabilities: ServerCapabilities {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: ["CASEMAPPING=ascii", "CHANTYPES=#"])
        return capabilities
    }

    private func message(
        from nick: String,
        _ body: String,
        kind: MessageKind = .privmsg,
        isAction: Bool = false
    ) -> IRCEvent {
        .message(
            target: Target("#swift", capabilities: capabilities),
            sender: user(nick),
            text: body,
            kind: kind,
            isAction: isAction
        )
    }

    // MARK: - mIRC's shapes

    @Test("messages, actions and notices read like mIRC")
    func messageShapes() {
        #expect(text(message(from: "bob", "hello")) == "<bob> hello")
        #expect(text(message(from: "bob", "waves", isAction: true)) == "* bob waves")
        #expect(text(message(from: "bob", "heads up", kind: .notice)) == "-bob- heads up")
    }

    /// The nick column carries the highest-ranking prefix the sender holds, so who is an
    /// op is visible in the conversation rather than only in the nick list.
    @Test("the nick column includes the sender's prefix")
    func nickColumnPrefix() {
        #expect(text(message(from: "bob", "hello"), prefix: "@") == "<@bob> hello")
        #expect(text(message(from: "bob", "waves", isAction: true), prefix: "+") == "* +bob waves")
    }

    /// With no `echo-message` capability we echo our own messages, so the renderer has to
    /// know which are ours — that mark is what lets stage 2 drop the duplicate once the
    /// server starts sending them back instead.
    @Test("our own messages get their own kinds, matched case-insensitively")
    func ownMessagesAreMarked() throws {
        #expect(LineKind.ownMessage.isSelfEcho)
        #expect(LineKind.ownAction.isSelfEcho)
        #expect(LineKind.ownNotice.isSelfEcho)
        #expect(!LineKind.message.isSelfEcho)

        // Same words, different colour — which is how the two are told apart on screen.
        let table = LineFormatTable.mIRC
        #expect(table[.message].colour != table[.ownMessage].colour)
        #expect(table[.message].template == table[.ownMessage].template)

        let mine = try #require(
            renderer.line(
                for: message(from: "Alice", "mine"),
                context: RenderContext(ownNick: "alice")
            )
        )
        #expect(mine.runs.first?.appKit.foregroundColor == LineColour.ownText.nsColor)
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
            text(.quit(who: user("bob"), reason: "Ping timeout"))
                == "*** Quits: bob (Ping timeout)"
        )
        #expect(
            text(.nickChanged(who: user("bob"), newNick: "robert"))
                == "*** bob is now known as robert"
        )
        #expect(
            text(
                .kicked(
                    channel: IRCChannelName("#swift"),
                    by: user("carol"),
                    nick: "bob",
                    reason: "out"
                )
            ) == "*** bob was kicked from #swift by carol (out)"
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
        #expect(
            text(.topicChanged(channel: channel, who: nil, topic: ""))
                == "*** No topic is set for #swift"
        )
        #expect(
            text(.topicChanged(channel: channel, who: user("bob"), topic: ""))
                == "*** bob cleared the topic for #swift"
        )
    }

    @Test("a mode change and a mode reply are different sentences")
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
            ) == "*** bob sets mode: +on-v carol dave"
        )
        #expect(
            text(
                .channelModes(
                    channel: IRCChannelName("#swift", mapping: .ascii),
                    changes: [
                        ModeChange(isSet: true, mode: "n"), ModeChange(isSet: true, mode: "t"),
                    ]
                )
            ) == "*** Channel modes for #swift: +nt"
        )
    }

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
        #expect(
            text(.joinFailed(channel: IRCChannelName("#swift"), reason: .inviteOnly, text: ""))
                == "*** Cannot join #swift: the channel is invite only"
        )
    }

    /// The MOTD arrives as numerics, and every one of them repeats our own nick.
    @Test("a numeric drops the leading copy of our own nick")
    func numericDropsOwnNick() {
        let event = IRCEvent.numeric(code: 372, parameters: ["alice", "- welcome to the network"])
        #expect(text(event) == "- welcome to the network")
        #expect(text(event, ownNick: "carol") == "alice - welcome to the network")
    }

    /// State, not a thing that happened. The nick list, the header band and the tree row
    /// are where these land; `.raw` has the raw-traffic toggle.
    @Test("state events and raw lines render nothing here")
    func silentEvents() throws {
        let message = try #require(IRCMessage(line: ":irc.example.org 372 alice :text"))
        #expect(text(.raw(message)) == nil)
        #expect(text(.channelChanged(Channel(name: IRCChannelName("#swift")))) == nil)
        #expect(text(.channelClosed(IRCChannelName("#swift"))) == nil)
        #expect(text(.namesReply(channel: IRCChannelName("#swift"), names: ["bob"])) == nil)
        #expect(text(.endOfNames(channel: IRCChannelName("#swift"))) == nil)
    }

    // MARK: - Timestamps

    /// Fixed width by construction: a monospaced font plus a fixed-width format is what
    /// makes the message text form a clean left edge, with no column arithmetic anywhere.
    @Test("the default format puts a fixed-width timestamp in front of the line")
    func timestampColumn() throws {
        let line = try #require(
            LineRenderer().line(
                for: message(from: "bob", "hello"),
                context: RenderContext(ownNick: "alice")
            )
        )
        let rendered = String(line.characters)
        #expect(rendered.hasSuffix("<bob> hello"))

        let prefix = rendered.dropLast("<bob> hello".count)
        #expect(prefix.count == "[00:00:00] ".count)
        #expect(prefix.first == "[")
        #expect(prefix.hasSuffix("] "))
    }

    @Test("an empty format removes the timestamp and its space entirely")
    func timestampsOff() {
        #expect(text(message(from: "bob", "hello")) == "<bob> hello")
    }

    /// Dim, so the eye skips it — and dimmed by range rather than by searching the output,
    /// which would find the wrong digits the moment a nick contains some.
    @Test("the timestamp is dimmed independently of the rest of the line")
    func timestampIsDim() throws {
        let line = try #require(
            LineRenderer().line(
                for: message(from: "12:00:00", "hello"),
                context: RenderContext(ownNick: "alice")
            )
        )
        // The AppKit scope explicitly: with both attribute scopes in play a bare
        // `foregroundColor` resolves to SwiftUI's `Color`.
        let colours = line.runs.map { $0.appKit.foregroundColor }
        #expect(colours.first == LineColour.dim.nsColor)
        #expect(colours.contains(LineColour.text.nsColor))
    }

    // MARK: - The format table as a seam

    /// The whole point of the table: changing it changes the output without touching the
    /// renderer. This is what stage 3's Colors dialog and stage 2's themes reach for.
    @Test("a different table produces different lines from the same event")
    func tableIsTheSeam() {
        let table = LineFormatTable(formats: [
            .message: LineFormat(template: "$nick said $text", colour: .error)
        ])
        let renderer = LineRenderer(table: table, timestampFormat: "")
        let line = renderer.line(
            for: message(from: "bob", "hello"),
            context: RenderContext(ownNick: "alice")
        )
        #expect(line.map { String($0.characters) } == "bob said hello")
        // The *last* run, not the first: the nick column now wears its own hash colour, so
        // the first run is bob's colour rather than the table's.
        #expect(line?.runs.last?.appKit.foregroundColor == LineColour.error.nsColor)
    }

    /// Every kind has an entry, or a line somewhere renders as bare text with no warning.
    @Test("the shipped table covers every line kind")
    func tableIsComplete() {
        for kind in LineKind.allCases {
            #expect(!LineFormatTable.mIRC[kind].template.isEmpty, "no format for \(kind)")
        }
    }

    /// A template naming something this build does not have keeps the text as written
    /// rather than swallowing it, so a bad theme is visibly bad.
    @Test("an unknown variable survives expansion")
    func unknownVariable() {
        var fields = LineFields()
        fields.nick = "bob"
        let format = LineFormat(template: "$nick $nonesuch $nick", colour: .text)
        #expect(format.expand(fields).text == "bob $nonesuch bob")
    }

    @Test("a variable with no value expands to nothing")
    func emptyVariable() {
        let format = LineFormat(template: "*** Quits: $nick$reason", colour: .event)
        var fields = LineFields()
        fields.nick = "bob"
        #expect(format.expand(fields).text == "*** Quits: bob")
    }

    // MARK: - Raw traffic and the unread rule

    @Test("raw lines carry their direction marker")
    func rawLines() {
        #expect(String(renderer.line("PING :x", kind: .rawInbound).characters) == "<< PING :x")
        #expect(String(renderer.line("PONG :x", kind: .rawOutbound).characters) == ">> PONG :x")
    }

    /// Longer than any window on purpose: it is drawn with a clipping paragraph style, so
    /// an over-long rule spans the width whatever the width is, where a measured one would
    /// be wrong the moment the window is resized.
    @Test("the unread rule is a bare rule with no timestamp")
    func unreadRule() {
        let rule = String(LineRenderer().unreadRule().characters)
        #expect(rule.allSatisfy { $0 == "─" })
        #expect(rule.count > 200)
    }

    // MARK: - Connection state

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
        #expect(text(.stateChanged(.disconnected(reason: reason)))?.contains(expected) == true)
    }

    @Test("a connection that never started says nothing")
    func notStartedIsSilent() {
        #expect(text(.stateChanged(.disconnected(reason: .notStarted))) == nil)
        #expect(LineRenderer.statusLine(for: .disconnected(reason: .notStarted)) == nil)
    }

    @Test("reconnecting reports the attempt and the wait")
    func reconnecting() {
        #expect(
            text(.stateChanged(.reconnecting(attempt: 3, nextAttemptIn: .milliseconds(1500))))
                == "*** Reconnecting (attempt 3) in 1.5s"
        )
    }

    // MARK: - Links

    @Test("URLs in a line become links")
    func detectsLinks() {
        let line = renderer.line("see https://example.org/page for details", kind: .numeric)
        #expect(line.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.org/page"])
    }

    @Test("a line with no URL is not scanned for one")
    func noLinks() {
        let line = renderer.line("nothing to see here", kind: .numeric)
        #expect(line.runs.allSatisfy { $0.link == nil })
    }
}
