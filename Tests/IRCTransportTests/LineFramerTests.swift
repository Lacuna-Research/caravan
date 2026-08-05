import Foundation
import Testing

@testable import IRCTransport

/// The framer is where framing bugs hide, and they hide specifically at chunk
/// boundaries — so most of this file is about where the chunks are cut, not what is
/// in them.
@Suite("LineFramer")
struct LineFramerTests {
    /// Convenience: push a `String` as one chunk and take the decoded lines.
    private func lines(of framer: inout LineFramer, _ chunk: String) -> [String] {
        framer.push(Data(chunk.utf8)).lines.map { WireDecoding.line(from: $0) }
    }

    @Test("splits a single terminated line")
    func singleLine() {
        var framer = LineFramer()
        #expect(lines(of: &framer, "PING :1\r\n") == ["PING :1"])
        #expect(framer.pendingByteCount == 0)
    }

    @Test("splits several lines from one chunk")
    func severalLinesOneChunk() {
        var framer = LineFramer()
        #expect(
            lines(of: &framer, "NICK a\r\nUSER b 0 * :c\r\nPING :1\r\n") == [
                "NICK a", "USER b 0 * :c", "PING :1",
            ]
        )
    }

    @Test("tolerates a bare LF terminator")
    func bareLineFeed() {
        var framer = LineFramer()
        #expect(lines(of: &framer, "PING :1\nPONG :1\n") == ["PING :1", "PONG :1"])
    }

    @Test("mixes CRLF and bare LF in one stream")
    func mixedTerminators() {
        var framer = LineFramer()
        #expect(lines(of: &framer, "a\r\nb\nc\r\n") == ["a", "b", "c"])
    }

    /// A lone CR is data. Stripping it would corrupt any line that legitimately
    /// contains one.
    @Test("a bare CR is content, not a terminator")
    func bareCarriageReturn() {
        var framer = LineFramer()
        #expect(lines(of: &framer, "PRIVMSG #x :a\rb\r\n") == ["PRIVMSG #x :a\rb"])
    }

    @Test("holds an unterminated line until its terminator arrives")
    func holdsUnterminated() {
        var framer = LineFramer()
        #expect(lines(of: &framer, "PING :1").isEmpty)
        #expect(framer.pendingByteCount == 7)
        #expect(lines(of: &framer, "\r\n") == ["PING :1"])
    }

    /// The classic off-by-one-chunk bug: the CR ends one read and the LF starts the next.
    @Test("handles a chunk boundary between CR and LF")
    func boundaryInsideCRLF() {
        var framer = LineFramer()
        #expect(lines(of: &framer, "PING :1\r").isEmpty)
        #expect(lines(of: &framer, "\nPONG :1\r\n") == ["PING :1", "PONG :1"])
    }

    @Test("reassembles a line delivered one byte at a time")
    func byteAtATime() {
        var framer = LineFramer()
        var collected: [String] = []
        for byte in Array("PRIVMSG #chan :hello there\r\n".utf8) {
            collected += framer.push(Data([byte])).lines.map { WireDecoding.line(from: $0) }
        }
        #expect(collected == ["PRIVMSG #chan :hello there"])
    }

    @Test("reassembles a line split across many chunks")
    func splitAcrossManyChunks() {
        var framer = LineFramer()
        var collected: [String] = []
        for piece in ["PRIV", "MSG #cha", "n :hel", "lo\r", "\n"] {
            collected += lines(of: &framer, piece)
        }
        #expect(collected == ["PRIVMSG #chan :hello"])
    }

    @Test("an empty chunk yields nothing and disturbs nothing")
    func emptyChunk() {
        var framer = LineFramer()
        #expect(lines(of: &framer, "PING").isEmpty)
        #expect(framer.push(Data()).lines.isEmpty)
        #expect(lines(of: &framer, "\r\n") == ["PING"])
    }

    /// Stray CRLF pairs reach the caller as empty lines rather than being swallowed
    /// here. The framer has no policy; ``IRCConnection`` traces them and drops them
    /// because they parse to no command.
    @Test("emits empty lines rather than deciding they are uninteresting")
    func emptyLines() {
        var framer = LineFramer()
        #expect(lines(of: &framer, "\r\n\r\nPING :1\r\n") == ["", "", "PING :1"])
    }

    @Test("drops an overlong line and recovers on the next one")
    func dropsOverlong() {
        var framer = LineFramer(maximumLineBytes: 16)
        let output = framer.push(Data((String(repeating: "x", count: 40) + "\r\nPING :1\r\n").utf8))
        #expect(output.droppedOverlongLines == 1)
        #expect(output.lines.map { WireDecoding.line(from: $0) } == ["PING :1"])
    }

    /// The failure this limit exists to prevent: a peer that never sends a terminator
    /// must not be able to grow our buffer without bound.
    @Test("a terminator-free flood does not accumulate")
    func floodDoesNotAccumulate() {
        var framer = LineFramer(maximumLineBytes: 64)
        var dropped = 0
        for _ in 0..<1000 {
            dropped +=
                framer.push(Data(String(repeating: "x", count: 1024).utf8)).droppedOverlongLines
        }
        #expect(dropped == 1)  // Still the same unterminated line.
        #expect(framer.pendingByteCount == 0)
    }

    @Test("keeps a line of exactly the maximum length")
    func exactlyAtLimit() {
        var framer = LineFramer(maximumLineBytes: 8)
        let output = framer.push(Data("12345678\r\n".utf8))
        #expect(output.droppedOverlongLines == 0)
        #expect(output.lines.map { WireDecoding.line(from: $0) } == ["12345678"])
    }

    @Test("discards the tail of an overlong line spread across chunks")
    func overlongAcrossChunks() {
        var framer = LineFramer(maximumLineBytes: 8)
        #expect(framer.push(Data("123456789".utf8)).droppedOverlongLines == 1)
        #expect(lines(of: &framer, "still the same line").isEmpty)
        #expect(lines(of: &framer, "\r\nPING :1\r\n") == ["PING :1"])
    }

    @Test("the default limit accommodates a full tag section plus message")
    func defaultLimit() {
        #expect(LineFramer.defaultMaximumLineBytes == 8191 + 512)
    }
}
