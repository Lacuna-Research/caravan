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

    // MARK: - The live feed

    /// What `/debug` subscribes to. Events recorded after subscribing arrive in order.
    @Test("a feed carries what is recorded after it starts")
    func feedIsLive() async {
        let buffer = TraceBuffer(capacity: 8)
        let (retained, events) = buffer.feed()
        #expect(retained.isEmpty)

        buffer.record(.outbound, line: "NICK alice")
        buffer.record(.inbound, line: ":server 001 alice :hi")

        var received: [String] = []
        for await event in events {
            received.append(event.line)
            if received.count == 2 { break }
        }
        #expect(received == ["NICK alice", ":server 001 alice :hi"])
    }

    /// `/debug -i` exists because problems are noticed after they happen. The retained
    /// events and the subscription are taken under one lock, so nothing recorded in
    /// between is dropped or delivered twice.
    @Test("a feed can include what the ring already holds")
    func feedIncludingRetained() async {
        let buffer = TraceBuffer(capacity: 8)
        buffer.record(.outbound, line: "before one")
        buffer.record(.inbound, line: "before two")

        let (retained, events) = buffer.feed(includingRetained: true)
        #expect(retained.map(\.line) == ["before one", "before two"])

        buffer.record(.inbound, line: "after")
        var received: [String] = []
        for await event in events {
            received.append(event.line)
            break
        }
        #expect(received == ["after"])
    }

    /// The retained events are redacted, like everything else in the ring — a `-i` replay
    /// is not a back door around the redaction.
    @Test("retained events come back redacted")
    func feedRetainedIsRedacted() {
        let buffer = TraceBuffer(capacity: 8)
        buffer.record(.outbound, line: "PASS hunter2")
        let (retained, _) = buffer.feed(includingRetained: true)
        #expect(retained.first?.line.contains("hunter2") == false)
    }

    /// A subscriber that goes away must be forgotten, or the buffer leaks a continuation
    /// per `/debug` for the life of the process.
    @Test("a finished feed unsubscribes")
    func feedUnsubscribes() async {
        let buffer = TraceBuffer(capacity: 8)
        do {
            let (_, events) = buffer.feed()
            #expect(buffer.subscriberCount == 1)
            var iterator = events.makeAsyncIterator()
            buffer.record(.inbound, line: "one")
            _ = await iterator.next()
        }
        // Termination is asynchronous, so this is the property, waited for.
        var attempts = 0
        while buffer.subscriberCount > 0 && attempts < 100 {
            try? await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        #expect(buffer.subscriberCount == 0)
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
