import Testing

@testable import IRCProtocol

/// The CTCP wrapper, in both directions.
///
/// A parser and a table, so it is worth being exhaustive about the awkward spellings —
/// they are what arrives from a real network, and every one of them used to render as
/// control characters in a channel window.
@Suite("CTCP")
struct CTCPTests {
    @Test(
        "the shapes a request arrives in",
        arguments: [
            ("\u{01}VERSION\u{01}", "VERSION", String?.none),
            ("\u{01}PING 1728394\u{01}", "PING", "1728394"),
            ("\u{01}ACTION waves at bob\u{01}", "ACTION", "waves at bob"),
            // Truncated at 512 bytes: still a request. Showing it beats showing `^A`.
            ("\u{01}VERSION", "VERSION", nil),
            ("\u{01}PING 1728394", "PING", "1728394"),
            // A trailing space is a present-but-empty argument, and `PING` has to echo
            // back exactly what it was given.
            ("\u{01}PING \u{01}", "PING", ""),
            // Case is the sender's business; `keyword` is what comparison uses.
            ("\u{01}version\u{01}", "version", nil),
            // An argument may hold anything, delimiters included after the first split.
            ("\u{01}USERINFO a b c\u{01}", "USERINFO", "a b c"),
        ]
    )
    func parsing(text: String, command: String, argument: String?) throws {
        let ctcp = try #require(CTCPMessage(text: text))
        #expect(ctcp.command == command)
        #expect(ctcp.argument == argument)
    }

    /// **Only a leading delimiter counts.** A `\u{01}` in the middle of a paste is a stray
    /// control character, not a request, and answering one is how a client is talked into
    /// replying to something nobody sent.
    @Test(
        "what is not a CTCP",
        arguments: [
            "a normal message",
            "hello \u{01}VERSION\u{01}",
            "VERSION",
            "",
            // A bare wrapper names no keyword, so there is nothing to answer.
            "\u{01}\u{01}",
            "\u{01}",
            "\u{01} VERSION\u{01}",
        ]
    )
    func notCTCP(text: String) {
        #expect(CTCPMessage(text: text) == nil)
    }

    @Test("keyword folds case, ACTION is recognised however it is spelled")
    func keywords() throws {
        #expect(try #require(CTCPMessage(text: "\u{01}version\u{01}")).keyword == "VERSION")
        #expect(try #require(CTCPMessage(text: "\u{01}action hi\u{01}")).isAction)
        #expect(try #require(CTCPMessage(text: "\u{01}ACTION hi\u{01}")).isAction)
        // `ACTIONS` is a different keyword. Matching it as an action would eat its `S`.
        #expect(try !#require(CTCPMessage(text: "\u{01}ACTIONS are cool\u{01}")).isAction)
    }

    @Test("a message survives a round trip through the wire form")
    func roundTrip() throws {
        for text in [
            "\u{01}VERSION\u{01}", "\u{01}PING 123\u{01}", "\u{01}ACTION waves\u{01}",
            "\u{01}PING \u{01}",
        ] {
            #expect(try #require(CTCPMessage(text: text)).wireForm == text)
        }
    }

    @Test("the summary is what a buffer shows")
    func summaries() throws {
        #expect(try #require(CTCPMessage(text: "\u{01}VERSION\u{01}")).summary == "VERSION")
        #expect(try #require(CTCPMessage(text: "\u{01}PING 42\u{01}")).summary == "PING 42")
        // An empty argument adds nothing but a trailing space, which is not worth showing.
        #expect(try #require(CTCPMessage(text: "\u{01}PING \u{01}")).summary == "PING")
    }
}
