import Testing

@testable import Diagnostics

@Suite("TraceBuffer")
struct TraceBufferTests {
    @Test("records events oldest first")
    func recordsInOrder() {
        let buffer = TraceBuffer(capacity: 8)
        buffer.record(.outbound, line: "NICK alice")
        buffer.record(.inbound, line: "PING :1")
        buffer.record(.outbound, line: "PONG :1")

        let events = buffer.snapshot()
        #expect(events.map(\.line) == ["NICK alice", "PING :1", "PONG :1"])
        #expect(events.map(\.direction) == [.outbound, .inbound, .outbound])
    }

    @Test("evicts oldest events beyond capacity")
    func evictsOldest() {
        let buffer = TraceBuffer(capacity: 3)
        for index in 1...5 {
            buffer.record(.inbound, line: "line \(index)")
        }
        #expect(buffer.count == 3)
        #expect(buffer.snapshot().map(\.line) == ["line 3", "line 4", "line 5"])
    }

    @Test("wraps repeatedly without losing order")
    func wrapsRepeatedly() {
        let buffer = TraceBuffer(capacity: 4)
        for index in 1...23 {
            buffer.record(.inbound, line: "\(index)")
        }
        #expect(buffer.snapshot().map(\.line) == ["20", "21", "22", "23"])
    }

    /// The load-bearing property: there is no way to get an unredacted credential into
    /// the buffer, because redaction happens on insert rather than on export.
    @Test("redacts on insert, so credentials are never resident")
    func redactsOnInsert() {
        let buffer = TraceBuffer(capacity: 8)
        buffer.record(.outbound, line: "PASS hunter2")
        buffer.record(.outbound, line: "PRIVMSG NickServ :IDENTIFY hunter2")

        let lines = buffer.snapshot().map(\.line)
        #expect(lines == ["PASS <redacted>", "PRIVMSG NickServ :IDENTIFY <redacted>"])
        #expect(!lines.joined().contains("hunter2"))
    }

    @Test("timestamps are monotonically non-decreasing")
    func timestampsAdvance() {
        let buffer = TraceBuffer(capacity: 8)
        for index in 1...5 {
            buffer.record(.inbound, line: "\(index)")
        }
        let stamps = buffer.snapshot().map(\.timestamp)
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("clear empties the buffer")
    func clearEmpties() {
        let buffer = TraceBuffer(capacity: 4)
        buffer.record(.inbound, line: "x")
        buffer.clear()
        #expect(buffer.count == 0)
        #expect(buffer.snapshot().isEmpty)
    }

    @Test("empty buffer snapshots cleanly")
    func emptySnapshot() {
        #expect(TraceBuffer(capacity: 4).snapshot().isEmpty)
    }

    /// Written from the transport's hot path, so concurrent writes must not corrupt the
    /// ring or trip the exclusivity checker.
    @Test("survives concurrent writes")
    func concurrentWrites() async {
        let buffer = TraceBuffer(capacity: 64)
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<16 {
                group.addTask {
                    for index in 0..<50 {
                        buffer.record(.inbound, line: "task \(task) line \(index)")
                    }
                }
            }
        }
        #expect(buffer.count == 64)
        #expect(buffer.snapshot().count == 64)
    }
}
