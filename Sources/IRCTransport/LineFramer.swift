import Foundation
import IRCProtocol

/// Splits an arriving byte stream into complete IRC lines.
///
/// Pure and synchronous: no sockets, no queues, no logging, no decoding. Framing bugs
/// are the transport bugs hardest to reproduce against a live server — they need a
/// chunk to land on exactly the wrong byte — so the logic lives somewhere a test can
/// drive it one byte at a time.
///
/// A `\r\n` terminates a line and a bare `\n` does too, because real servers and
/// bouncers send both. A bare `\r` is data: stripping it would silently corrupt lines
/// that legitimately contain one.
public struct LineFramer: Sendable {
    /// What one call to ``push(_:)`` produced.
    public struct Output: Sendable, Equatable {
        /// Complete lines in arrival order, terminator removed.
        ///
        /// Bytes rather than `String`: decoding has its own fallback rules and its own
        /// tests, and a framer that decodes cannot be tested for framing alone.
        public var lines: [[UInt8]]

        /// How many overlong lines were discarded. The framer is pure and does not log;
        /// the caller turns a non-zero count into a diagnostic.
        public var droppedOverlongLines: Int

        public init(lines: [[UInt8]] = [], droppedOverlongLines: Int = 0) {
            self.lines = lines
            self.droppedOverlongLines = droppedOverlongLines
        }
    }

    /// Longest line assembled before giving up on it, excluding the terminator.
    ///
    /// The IRCv3 tag section and the rest of the message have separate budgets, so the
    /// largest legal line is their sum.
    public static let defaultMaximumLineBytes =
        IRCProtocolLimits.maximumTagSectionBytes + IRCProtocolLimits.maximumMessageBytes

    public let maximumLineBytes: Int

    private var partial: [UInt8] = []

    /// Set once a line has outgrown the limit: the rest of that line, however much of
    /// it arrives, is discarded with it rather than accumulating.
    private var discardingRemainderOfLine = false

    public init(maximumLineBytes: Int = LineFramer.defaultMaximumLineBytes) {
        precondition(maximumLineBytes > 0, "LineFramer needs a positive line limit")
        self.maximumLineBytes = maximumLineBytes
    }

    /// Bytes held for a line that has not been terminated yet.
    ///
    /// Exposed so a test can assert the buffer stays bounded when a hostile peer never
    /// sends a terminator — the failure mode the limit exists to prevent.
    public var pendingByteCount: Int { partial.count }

    /// Feeds one chunk in and takes whatever lines it completed.
    ///
    /// A line may span arbitrarily many chunks, and a chunk may end between the `\r`
    /// and the `\n`.
    public mutating func push(_ chunk: Data) -> Output {
        var output = Output()
        for byte in chunk {
            if byte == UInt8(ascii: "\n") {
                if discardingRemainderOfLine {
                    discardingRemainderOfLine = false
                } else {
                    if partial.last == UInt8(ascii: "\r") { partial.removeLast() }
                    output.lines.append(partial)
                }
                partial.removeAll(keepingCapacity: true)
                continue
            }
            guard !discardingRemainderOfLine else { continue }
            partial.append(byte)
            // A trailing CR does not count against the limit until the next byte proves
            // it was data rather than the first half of a terminator. Counting it would
            // drop a line of exactly the maximum length, which is a legal line.
            let contentBytes =
                partial.last == UInt8(ascii: "\r") ? partial.count - 1 : partial.count
            if contentBytes > maximumLineBytes {
                // Release the capacity too. Holding a 9 KB buffer for the rest of the
                // session is the leak this branch exists to avoid.
                partial = []
                discardingRemainderOfLine = true
                output.droppedOverlongLines += 1
            }
        }
        return output
    }
}
