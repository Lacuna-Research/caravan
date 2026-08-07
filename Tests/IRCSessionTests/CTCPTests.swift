import IRCProtocol
import Testing

@testable import IRCSession

/// What this client answers, and how often it is willing to.
@Suite("CTCP replies")
struct CTCPReplyTests {
    private func reply(to text: String) -> CTCPMessage? {
        guard let request = CTCPMessage(text: text) else {
            Issue.record("\(text) did not parse as a CTCP")
            return nil
        }
        return CTCPReplies.reply(
            to: request,
            version: "Caravan 0.1 (macOS)",
            userInfo: "A Tester",
            time: "Fri Aug 7 12:00:00 2026 +0000"
        )
    }

    @Test("the answered set, with its answers")
    func answers() throws {
        #expect(
            try #require(reply(to: "\u{01}VERSION\u{01}")).wireForm
                == "\u{01}VERSION Caravan 0.1 (macOS)\u{01}"
        )
        #expect(
            try #require(reply(to: "\u{01}TIME\u{01}")).wireForm
                == "\u{01}TIME Fri Aug 7 12:00:00 2026 +0000\u{01}"
        )
        #expect(
            try #require(reply(to: "\u{01}USERINFO\u{01}")).wireForm
                == "\u{01}USERINFO A Tester\u{01}"
        )
        #expect(
            try #require(reply(to: "\u{01}FINGER\u{01}")).wireForm
                == "\u{01}FINGER A Tester\u{01}"
        )
        #expect(
            try #require(reply(to: "\u{01}CLIENTINFO\u{01}")).argument
                == "ACTION CLIENTINFO FINGER PING TIME USERINFO VERSION"
        )
    }

    /// The sender is timing a round trip against a token it chose. A normalised answer is
    /// one it cannot match to its question.
    @Test("PING echoes its argument exactly, including having none")
    func ping() throws {
        #expect(try #require(reply(to: "\u{01}PING 1728394\u{01}")).argument == "1728394")
        #expect(try #require(reply(to: "\u{01}PING\u{01}")).argument == nil)
        #expect(try #require(reply(to: "\u{01}PING \u{01}")).argument == "")
    }

    /// A lower-case keyword is the same keyword. A client that only answered one spelling
    /// would look broken to whoever typed the other.
    @Test("keywords are matched case-insensitively")
    func caseInsensitive() throws {
        #expect(try #require(reply(to: "\u{01}version\u{01}")).command == "VERSION")
    }

    /// `ACTION` is a line of conversation. A client that answered one would answer every
    /// `/me` in every channel it sits in.
    @Test("ACTION is never answered, and nor is anything unrecognised")
    func silence() {
        #expect(reply(to: "\u{01}ACTION waves\u{01}") == nil)
        #expect(reply(to: "\u{01}DCC SEND file 1 2 3\u{01}") == nil)
        #expect(reply(to: "\u{01}SOUND boing.wav\u{01}") == nil)
        // Deliberately no ERRMSG: it is a free amplifier for whoever picks the keyword.
        #expect(reply(to: "\u{01}NONSENSE\u{01}") == nil)
    }

    /// Every keyword `CLIENTINFO` advertises is one this client actually understands.
    /// `ACTION` is understood without being answered, which is the one exception.
    @Test("CLIENTINFO advertises nothing it cannot do")
    func clientInfoIsHonest() {
        for keyword in CTCPReplies.supported where keyword != "ACTION" {
            #expect(reply(to: "\u{01}\(keyword)\u{01}") != nil, "\(keyword) is advertised")
        }
    }
}

/// The rate limit, which is the whole defence against being used as an amplifier.
@Suite("CTCP throttle")
struct CTCPThrottleTests {
    private let start = ContinuousClock.now

    @Test("a burst is allowed, and then it is not")
    func burst() {
        var throttle = CTCPThrottle(burst: 5, recovery: .seconds(5), now: start)
        for index in 0..<5 {
            #expect(throttle.admit(at: start) == .allowed, "reply \(index) should go out")
        }
        #expect(throttle.admit(at: start) == .suppressed(firstOfBurst: true))
    }

    /// Fifty requests, far fewer answers — the acceptance run, as a unit test.
    @Test("fifty requests at once produce five replies")
    func flood() {
        var throttle = CTCPThrottle(burst: 5, recovery: .seconds(5), now: start)
        let allowed = (0..<50).filter { _ in throttle.admit(at: start) == .allowed }.count
        #expect(allowed == 5)
    }

    /// Said once per run of suppressions. Fifty "not answering" lines would be the flood
    /// arriving by a second route.
    @Test("only the first suppression of a burst is worth telling anyone about")
    func firstOfBurst() {
        var throttle = CTCPThrottle(burst: 1, recovery: .seconds(5), now: start)
        #expect(throttle.admit(at: start) == .allowed)
        #expect(throttle.admit(at: start) == .suppressed(firstOfBurst: true))
        #expect(throttle.admit(at: start) == .suppressed(firstOfBurst: false))
        #expect(throttle.admit(at: start) == .suppressed(firstOfBurst: false))

        // A token comes back, is spent, and the next run of suppressions announces itself
        // again — otherwise a flood an hour later would be silent.
        #expect(throttle.admit(at: start + .seconds(5)) == .allowed)
        #expect(throttle.admit(at: start + .seconds(5)) == .suppressed(firstOfBurst: true))
    }

    @Test("tokens come back at one per recovery interval, and stop at the burst size")
    func refill() {
        var throttle = CTCPThrottle(burst: 3, recovery: .seconds(10), now: start)
        for _ in 0..<3 { _ = throttle.admit(at: start) }
        #expect(throttle.admit(at: start + .seconds(9)) == .suppressed(firstOfBurst: true))
        #expect(throttle.admit(at: start + .seconds(10)) == .allowed)
        #expect(throttle.admit(at: start + .seconds(10)) == .suppressed(firstOfBurst: true))

        // An hour of quiet refills the bucket and no more: the burst is a ceiling, not a
        // budget that accumulates while nobody is asking.
        let later = start + .seconds(3600)
        for _ in 0..<3 { #expect(throttle.admit(at: later) == .allowed) }
        #expect(throttle.admit(at: later) == .suppressed(firstOfBurst: true))
    }
}
