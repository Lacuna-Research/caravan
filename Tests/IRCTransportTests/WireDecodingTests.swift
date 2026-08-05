import Foundation
import Testing

@testable import IRCTransport

@Suite("WireDecoding")
struct WireDecodingTests {
    @Test("decodes UTF-8")
    func utf8() {
        #expect(WireDecoding.line(from: Array("PRIVMSG #x :héllo ☕️".utf8)) == "PRIVMSG #x :héllo ☕️")
    }

    /// 0xE9 is a valid Latin-1 'é' and an invalid UTF-8 lead byte. Losing this line
    /// entirely would be worse than showing it in the wrong encoding.
    @Test("falls back to Windows-1252 for invalid UTF-8")
    func windows1252Fallback() {
        let bytes = Array("PRIVMSG #x :caf".utf8) + [0xE9]
        #expect(WireDecoding.line(from: bytes) == "PRIVMSG #x :café")
    }

    /// 0x93/0x94 are smart quotes in Windows-1252 and C1 controls in Latin-1 — the
    /// distinction that makes cp1252 the better first fallback.
    @Test("maps the Windows-1252 upper range rather than treating it as control codes")
    func windows1252UpperRange() {
        let decoded = WireDecoding.line(
            from: Array("say ".utf8) + [0x93] + Array("hi".utf8) + [0x94]
        )
        #expect(decoded == "say “hi”")
    }

    @Test("never fails, whatever the bytes are")
    func neverFails() {
        for byte in UInt8.min...UInt8.max {
            #expect(!WireDecoding.line(from: [byte, 0x41]).isEmpty)
        }
    }

    @Test("encodes with a CRLF terminator")
    func encodesWithTerminator() {
        #expect(Array(WireDecoding.data(for: "PING :1")) == Array("PING :1\r\n".utf8))
    }
}
