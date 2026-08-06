import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import IRCTransport
import Testing

@testable import CaravanUI

/// Prompt 7's acceptance criterion, as far as it can be automated: connect to Libera over
/// TLS and watch the MOTD arrive in a real `NSTextView`.
///
/// Off unless `CARAVAN_LIVE_TESTS` is set.
///
///     CARAVAN_LIVE_TESTS=1 swift test --filter LiveScrollbackTests
///
/// The eye-level half of the acceptance — that it *looks* right — is a screenshot in the
/// build log. This half is the one a machine can keep honest: that every MOTD line made
/// it through the session, the event stream, the renderer and into the text storage.
@MainActor
@Suite(
    "live scrollback",
    .enabled(if: ProcessInfo.processInfo.environment["CARAVAN_LIVE_TESTS"] != nil)
)
struct LiveScrollbackTests {
    @Test("the MOTD renders into the scrollback, and scroll-lock holds while it streams")
    func motdRenders() async throws {
        let nick = "caravan\(Int.random(in: 100_000...999_999))"
        let connection = ConnectionViewModel(
            configuration: SessionConfiguration(
                host: "irc.libera.chat",
                port: 6697,
                tls: .enabled(.system),
                nick: nick,
                realName: "Caravan test",
                connectTimeout: .seconds(30)
            ),
            trace: TraceBuffer(capacity: 4096)
        )

        // A real text view, configured exactly as the app configures it. A short viewport
        // so a real MOTD overflows it, which is what makes scrolling meaningful at all.
        let textView = MessageLogView.makeTextView(usesTextKit2: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 150))
        scrollView.documentView = textView
        connection.log.attach(textView: textView, scrollView: scrollView)
        scrollView.layoutSubtreeIfNeeded()

        await connection.connect()
        #expect(await waitUntil(timeout: .seconds(40)) { connection.isConnected })

        // 376 ends the MOTD.
        #expect(
            await waitUntil(timeout: .seconds(30)) {
                connection.log.flush()
                return textView.string.contains("End of /MOTD")
            }
        )
        let lineCount = connection.log.lineCount
        #expect(lineCount > 20, "a real MOTD is dozens of lines, got \(lineCount)")
        #expect(textView.string.contains("Registered as \(nick)"))
        #expect(textView.frame.height > scrollView.contentView.bounds.height)

        // Scroll up, then keep appending. The view must stay where it was put — the same
        // invariant the unit suite covers deterministically, here against a document a
        // real server filled.
        scrollView.contentView.scroll(to: .zero)
        connection.log.scrollPositionChanged()
        #expect(!connection.log.isPinnedToBottom)
        let heldOrigin = scrollView.contentView.bounds.origin.y

        connection.log.append(
            [LineRenderer().line("a line arriving while you read history", kind: .numeric)]
        )
        connection.log.flush()

        #expect(!connection.log.isPinnedToBottom, "streaming lines must not steal the scroll")
        #expect(scrollView.contentView.bounds.origin.y == heldOrigin)
        #expect(connection.log.unseenLineCount == 1)

        connection.log.scrollToLatest()
        #expect(connection.log.isPinnedToBottom)

        print("LIVE: \(lineCount) lines rendered, \(textView.string.count) characters")
        await connection.disconnect()
    }

    /// Prompt 3's acceptance criterion: **your own message appears exactly once** with
    /// `echo-message` negotiated.
    ///
    /// Libera offers the capability, so this is the "with" half against a real server; the
    /// "without" half is deterministic and lives in `CapabilityBehaviourTests`. It is the
    /// half worth running live, because getting it wrong here means the client shows
    /// *nothing* when you type — a defect no unit test that mocks the server can prove is
    /// absent, and the one a user notices in the first minute.
    @Test("with echo-message, a message sent to a real server comes back exactly once")
    func echoMessageDoesNotDouble() async throws {
        let nick = "caravan\(Int.random(in: 100_000...999_999))"
        let channel = "##caravan-caps"
        let connection = ConnectionViewModel(
            configuration: SessionConfiguration(
                host: "irc.libera.chat",
                port: 6697,
                tls: .enabled(.system),
                nick: nick,
                realName: "Caravan test",
                connectTimeout: .seconds(30)
            ),
            trace: TraceBuffer(capacity: 4096)
        )
        await connection.connect()
        #expect(await waitUntil(timeout: .seconds(40)) { connection.isConnected })
        #expect(connection.capabilities.isEnabled(.echoMessage))

        let name = IRCChannelName(channel, mapping: .rfc1459)
        await connection.send(IRCMessage(verb: "JOIN", parameters: [channel]), from: nil)
        #expect(await waitUntil(timeout: .seconds(30)) { connection.buffer(named: name) != nil })
        let buffer = try #require(connection.buffer(named: name))

        let textView = MessageLogView.makeTextView(usesTextKit2: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        scrollView.documentView = textView
        buffer.log.attach(textView: textView, scrollView: scrollView)

        let body = "caravan echo-message check \(UUID().uuidString.prefix(8))"
        await connection.send(
            IRCMessage(verb: "PRIVMSG", parameters: [channel, body]),
            from: .channel(name)
        )
        #expect(
            await waitUntil(timeout: .seconds(20)) {
                buffer.log.flush()
                return textView.string.contains(body)
            }
        )
        // Give a duplicate every chance to arrive before counting.
        try await Task.sleep(for: .seconds(2))
        buffer.log.flush()
        let occurrences = textView.string.components(separatedBy: body).count - 1
        #expect(occurrences == 1, "expected exactly one copy, got \(occurrences)")
        // Still drawn as ours, in the nick column, wearing whatever prefix we hold — we
        // are opped in a channel we just created, so the live form is `<@nick>`.
        #expect(textView.string.contains("\(nick)> \(body)"))
        #expect(textView.string.contains("<@\(nick)>") || textView.string.contains("<\(nick)>"))

        await connection.quit(reason: "acceptance run")
    }
}
