import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The file itself: where it goes, what a line looks like, and what comes back off the end.
@MainActor
@Suite("Chat logs on disk")
struct ChatLogFileTests {
    @Test("a line goes in and comes back off the tail, oldest first")
    func roundTrip() {
        let log = temporaryChatLog()
        for index in 1...5 { log.write("line \(index)", network: "libera", buffer: "#swift") }
        #expect(log.tail(3, network: "libera", buffer: "#swift") == ["line 3", "line 4", "line 5"])
        #expect(log.tail(50, network: "libera", buffer: "#swift").count == 5)
        #expect(log.tail(0, network: "libera", buffer: "#swift").isEmpty)
    }

    @Test("a buffer with no log yet reads as empty rather than failing")
    func absentFile() {
        let log = temporaryChatLog()
        #expect(log.tail(10, network: "libera", buffer: "#nothing").isEmpty)
        #expect(log.networks().isEmpty)
    }

    /// **The case that would otherwise be a directory traversal.** A channel name is
    /// whatever the server accepts, and `#a/b` taken literally is a path.
    @Test("a buffer name that would be a path becomes one file, not a tree")
    func escaping() {
        #expect(ChatLog.escape("#a/b") == "#a%2Fb")
        #expect(ChatLog.escape("#a:b") == "#a%3Ab")
        #expect(ChatLog.escape("100%") == "100%25")
        #expect(ChatLog.escape("..") == "%2E.")
        // Nicks legitimately contain these, and escaping them would make the folder
        // unreadable for no safety gained.
        #expect(ChatLog.escape("|bob|[a]{b}\\c^d") == "|bob|[a]{b}\\c^d")

        let log = temporaryChatLog()
        log.write("hello", network: "libera", buffer: "#a/b")
        let url = log.url(network: "libera", buffer: "#a/b")
        #expect(url.lastPathComponent == "#a%2Fb.log")
        #expect(url.deletingLastPathComponent().lastPathComponent == "libera")
        #expect(log.tail(1, network: "libera", buffer: "#a/b") == ["hello"])
        // And it comes back out of a directory scan under the name it was written with.
        #expect(log.buffers(in: "libera") == ["#a/b"])
    }

    /// `%` is escaped first, without which `#a/b` and `#a%2Fb` would be one file.
    @Test("escaping is reversible")
    func escapingRoundTrips() {
        for name in ["#a/b", "#a%2Fb", "100%", "#plain", "bob[home]"] {
            #expect(ChatLog.unescape(ChatLog.escape(name)) == name)
        }
    }

    /// A log a year old is megabytes; the fifty lines somebody wants are at the end of it.
    @Test("a file larger than the tail window still yields whole lines from the end")
    func largeFile() throws {
        let log = temporaryChatLog()
        let filler = String(repeating: "x", count: 200)
        // Comfortably past the window, so the read starts mid-line and has to discard it.
        for index in 1...8000 {
            log.write("[stamp \(index)] \(filler)", network: "libera", buffer: "#big")
        }
        let url = log.url(network: "libera", buffer: "#big")
        log.close()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect((size ?? 0) > ChatLog.tailWindow)

        let tail = ChatLog.tail(3, of: url)
        #expect(tail.count == 3)
        #expect(tail.last == "[stamp 8000] \(filler)")
        // No half line survived the cut.
        #expect(tail.allSatisfy { $0.hasPrefix("[stamp ") })
    }

    @Test("the stamp round-trips to the second")
    func stamp() throws {
        let now = Date()
        let text = ChatLog.stamp(now)
        #expect(text.count == ChatLog.stampWidth)
        let parsed = try #require(ChatLog.date(fromStamp: text))
        #expect(abs(parsed.timeIntervalSince(now)) < 1)
        #expect(ChatLog.stamp(parsed) == text)
    }

    /// The file is text and somebody may well have typed in it.
    @Test("anything that is not a stamp is refused rather than guessed at")
    func badStamps() {
        for text in ["", "not a stamp at all", "2026-08-07 14:32:0", "2026/08/07 14:32:05"] {
            #expect(ChatLog.date(fromStamp: text) == nil)
        }
    }
}

/// Reading a line back far enough to know whether it is the same line as one arriving.
@MainActor
@Suite("Reading a logged line")
struct LoggedLineTests {
    @Test("a message line yields who said it and what they said")
    func message() throws {
        let line = LoggedLine("[2026-08-07 14:32:05] <@bob> hello there")
        let key = try #require(line.key)
        #expect(key.stamp == "2026-08-07 14:32:05")
        // Undecorated: bob may have lost his op between the write and the replay.
        #expect(key.nick == "bob")
        #expect(key.text == "hello there")
        #expect(line.date != nil)
        #expect(line.text == "[2026-08-07 14:32:05] <@bob> hello there")
    }

    @Test("an action and a notice are keyed too, and an event line is not")
    func otherShapes() throws {
        let action = try #require(LoggedLine("[2026-08-07 14:32:05] * bob waves at you").key)
        #expect(action.nick == "bob")
        #expect(action.text == "waves at you")

        let notice = try #require(LoggedLine("[2026-08-07 14:32:05] -NickServ- hello").key)
        #expect(notice.nick == "NickServ")
        #expect(notice.text == "hello")

        // `***` is an event, not somebody speaking — and `chathistory` never replays one,
        // so there is nothing for it to collide with.
        #expect(LoggedLine("[2026-08-07 14:32:05] *** Joins: bob (u@h) #swift").key == nil)
        #expect(LoggedLine("[2026-08-07 14:32:05] *** Quits: bob").key == nil)
    }

    @Test("a line with no stamp is carried whole and keyed not at all")
    func unstamped() {
        let line = LoggedLine("something a person typed into the file")
        #expect(line.date == nil)
        #expect(line.key == nil)
        #expect(line.text == "something a person typed into the file")
    }

    /// A nick may begin with `[ \ ] ^ _ { | }`, so only the membership prefixes come off.
    @Test("only a membership prefix is stripped from a nick")
    func undecorating() {
        #expect(ReplayKey.undecorated("@bob") == "bob")
        #expect(ReplayKey.undecorated("+bob") == "bob")
        #expect(ReplayKey.undecorated("~bob") == "bob")
        #expect(ReplayKey.undecorated("|bob|") == "|bob|")
        #expect(ReplayKey.undecorated("[away]bob") == "[away]bob")
    }
}

/// The index that decides whether an arriving line is one already on screen.
@MainActor
@Suite("De-duplicating a replay")
struct ReplayIndexTests {
    private func key(_ text: String, msgid: String? = nil, second: Int = 5) -> ReplayKey {
        ReplayKey(
            msgid: msgid,
            stamp: "2026-08-07 14:32:0\(second)",
            nick: "bob",
            text: text
        )
    }

    @Test("a line already held is recognised and suppressed")
    func matchesOnTheTriple() {
        let index = ReplayIndex()
        index.remember(key("hello"))
        #expect(index.consume(key("hello")))
        // Consumed: a second copy would be a third line, and there were only two.
        #expect(!index.consume(key("hello")))
    }

    @Test("a different second, nick or word is a different line")
    func doesNotOverMatch() {
        let index = ReplayIndex()
        index.remember(key("hello"))
        #expect(!index.consume(key("hello", second: 6)))
        #expect(!index.consume(key("goodbye")))
        #expect(
            !index.consume(
                ReplayKey(stamp: "2026-08-07 14:32:05", nick: "carol", text: "hello")
            )
        )
        // None of the misses ate it.
        #expect(index.consume(key("hello")))
    }

    /// The whole reason a hit consumes its entry.
    @Test("the same word twice in one second is two lines and stays two lines")
    func repeatedWithinASecond() {
        let index = ReplayIndex()
        index.remember(key("lol"))
        index.remember(key("lol"))
        #expect(index.consume(key("lol")))
        #expect(index.consume(key("lol")))
        #expect(!index.consume(key("lol")))
    }

    /// Where both sides carry an id it decides, and it decides *against* a match too.
    @Test("a message id outranks the triple in both directions")
    func messageIDWins() {
        let index = ReplayIndex()
        index.remember(key("hello", msgid: "abc"))
        // Same words, same second, different id: a different message.
        #expect(!index.consume(key("hello", msgid: "xyz")))
        // Different words, same id: the same message, re-edited or re-rendered.
        #expect(index.consume(key("goodbye", msgid: "abc")))
    }

    /// One side without an id falls back to the triple, which is the log's only option.
    @Test("a logged line with no id still matches an arriving one that has one")
    func mixedKeys() {
        let index = ReplayIndex()
        index.remember(key("hello"))
        #expect(index.consume(key("hello", msgid: "abc")))
    }

    @Test("the index is bounded")
    func cap() {
        let index = ReplayIndex(cap: 3)
        for number in 1...10 { index.remember(key("line \(number)")) }
        #expect(index.count == 3)
        // The oldest went first.
        #expect(!index.consume(key("line 1")))
        #expect(index.consume(key("line 10")))
    }
}

/// What the log is *written* from, which is deliberately not what the buffer shows.
@MainActor
@Suite("Rendering a line for the log")
struct LogRenderingTests {
    private let sender = IRCSource.user(nick: "bob", user: "u", host: "h")

    private func message(_ text: String) -> IRCEvent {
        .message(
            target: .channel(IRCChannelName("#swift", mapping: .rfc1459)),
            sender: sender,
            text: text,
            kind: .privmsg,
            isAction: false,
            tags: IRCTags()
        )
    }

    /// A display setting must not be able to change the shape of the file.
    @Test("the log's stamp is canonical whatever the user's timestamp format is")
    func canonicalStamp() throws {
        let when = try #require(ChatLog.date(fromStamp: "2026-08-07 14:32:05"))
        let context = RenderContext(ownNick: "alice", now: when)
        for format in ["[HH:mm:ss]", "", "HH.mm", "yyyy"] {
            let renderer = LineRenderer(timestampFormat: format)
            let line = try #require(renderer.plainLine(for: message("hello"), context: context))
            #expect(line == "[2026-08-07 14:32:05] <bob> hello")
        }
    }

    @Test("formatting codes are stripped on the way into the file")
    func stripsCodes() throws {
        let when = try #require(ChatLog.date(fromStamp: "2026-08-07 14:32:05"))
        let renderer = LineRenderer()
        let line = try #require(
            renderer.plainLine(
                for: message("\u{02}bold\u{02} and \u{03}04red\u{03}"),
                context: RenderContext(ownNick: "alice", now: when)
            )
        )
        #expect(line == "[2026-08-07 14:32:05] <bob> bold and red")
        #expect(!line.contains("\u{02}"))
        #expect(!line.contains("\u{03}"))
    }

    /// The written line and the parsed line have to agree, or nothing de-duplicates.
    @Test("what the writer writes is what the reader keys")
    func writerAndReaderAgree() throws {
        let when = try #require(ChatLog.date(fromStamp: "2026-08-07 14:32:05"))
        let renderer = LineRenderer()
        let text = try #require(
            renderer.plainLine(
                for: message("hello there"),
                context: RenderContext(ownNick: "alice", now: when)
            )
        )
        let key = try #require(LoggedLine(text).key)
        let live = try #require(
            ConnectionViewModel.replayKey(for: message("hello there"), at: when)
        )
        #expect(key.stamp == live.stamp)
        #expect(key.nick == live.nick)
        #expect(key.text == live.text)
    }

    /// An event that produces no buffer line produces no log line either.
    @Test("state and wire traffic are not written down")
    func nothingToWrite() {
        let renderer = LineRenderer()
        let context = RenderContext(ownNick: "alice")
        #expect(
            renderer.plainLine(
                for: .raw(IRCMessage(verb: "PING", parameters: ["x"])),
                context: context
            ) == nil
        )
        #expect(renderer.plainLine(for: .batchEnded(reference: "x"), context: context) == nil)
    }
}
