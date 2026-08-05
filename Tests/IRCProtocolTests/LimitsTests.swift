import Testing

@testable import IRCProtocol

@Suite("Protocol limits")
struct LimitsTests {
    @Test("limits are the documented values")
    func constants() {
        #expect(IRCProtocolLimits.maximumMessageBytes == 512)
        #expect(IRCProtocolLimits.maximumTagSectionBytes == 8191)
    }

    @Test("byte count includes CRLF and counts UTF-8, not characters")
    func byteCounting() throws {
        let ascii = try #require(IRCMessage(line: "PING :x"))
        #expect(ascii.wireForm == "PING x")  // canonical form drops the needless colon
        #expect(ascii.wireByteCount == 8)  // 6 + CRLF

        // One emoji is many bytes; counting characters would under-report and produce
        // a line the server rejects.
        let emoji = try #require(IRCMessage(line: "PRIVMSG #x :👩‍👩‍👧‍👦"))
        #expect(emoji.wireByteCount > emoji.wireForm.count + 2)
    }

    @Test("an ordinary message fits, an oversized one does not")
    func fitsLimits() {
        let ordinary = IRCMessage(verb: "PRIVMSG", parameters: ["#chan", "hello"])
        #expect(ordinary.fitsProtocolLimits)

        let huge = IRCMessage(
            verb: "PRIVMSG",
            parameters: ["#chan", String(repeating: "x", count: 600)]
        )
        #expect(!huge.fitsProtocolLimits)
    }

    @Test("tags get their own budget, separate from the message")
    func tagsBudgetedSeparately() {
        // A tag section far larger than 512 bytes is fine, because tags are budgeted
        // against 8191 rather than counting toward the message limit.
        let bigTag = IRCTags([IRCTag(key: "t", value: String(repeating: "v", count: 2000))])
        let message = IRCMessage(tags: bigTag, verb: "PRIVMSG", parameters: ["#chan", "hi"])
        #expect(message.fitsProtocolLimits)

        let hugeTag = IRCTags([IRCTag(key: "t", value: String(repeating: "v", count: 9000))])
        let tooBig = IRCMessage(tags: hugeTag, verb: "PRIVMSG", parameters: ["#chan", "hi"])
        #expect(!tooBig.fitsProtocolLimits)
    }

    @Test("truncation never splits a character")
    func truncationKeepsCharactersWhole() {
        let text = "aé👩‍👩‍👧‍👦b"
        for limit in 0...text.utf8.count + 4 {
            let truncated = text.truncated(to: limit)
            #expect(truncated.utf8.count <= limit)
            // Still valid, still a prefix — nothing mangled.
            #expect(text.hasPrefix(truncated))
        }
    }

    @Test("truncation is a no-op when already short enough")
    func truncationNoOp() {
        #expect("hello".truncated(to: 100) == "hello")
        #expect("hello".truncated(to: 5) == "hello")
        #expect("hello".truncated(to: 4) == "hell")
        #expect("hello".truncated(to: 0) == "")
        #expect("hello".truncated(to: -1) == "")
    }

    @Test("truncating a multi-byte character drops it whole rather than corrupting it")
    func truncationDropsWholeCharacter() {
        let text = "aé"  // 'a' is 1 byte, 'é' is 2
        #expect(text.utf8.count == 3)
        #expect(text.truncated(to: 2) == "a")
        #expect(text.truncated(to: 3) == "aé")
    }
}
