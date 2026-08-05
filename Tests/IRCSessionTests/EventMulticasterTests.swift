import IRCProtocol
import Testing

@testable import IRCSession

@Suite("Event multicast")
struct EventMulticasterTests {
    private func event(_ text: String) -> IRCEvent {
        .clientError(text)
    }

    /// The reason this exists at all: a single `AsyncStream` would give each consumer an
    /// arbitrary half of the events.
    @Test("every subscriber sees every event")
    func allSubscribersSeeEverything() async {
        let multicaster = EventMulticaster()
        let first = multicaster.subscribe()
        let second = multicaster.subscribe()
        let third = multicaster.subscribe()

        for index in 1...5 { multicaster.broadcast(event("\(index)")) }
        multicaster.finish()

        for stream in [first, second, third] {
            var received: [IRCEvent] = []
            for await event in stream { received.append(event) }
            #expect(received == (1...5).map { event("\($0)") })
        }
    }

    @Test("a subscriber sees only what follows its subscription")
    func noReplay() async {
        let multicaster = EventMulticaster()
        multicaster.broadcast(event("before"))
        let stream = multicaster.subscribe()
        multicaster.broadcast(event("after"))
        multicaster.finish()

        var received: [IRCEvent] = []
        for await event in stream { received.append(event) }
        #expect(received == [event("after")])
    }

    /// The documented drop policy: a stalled consumer loses its *oldest* unread events
    /// and skips ahead to what is happening now.
    @Test("a full buffer drops the oldest events, not the newest")
    func dropsOldest() async {
        let multicaster = EventMulticaster()
        let stream = multicaster.subscribe()

        let overflow = EventMulticaster.bufferSize + 50
        for index in 1...overflow { multicaster.broadcast(event("\(index)")) }
        multicaster.finish()

        var received: [IRCEvent] = []
        for await event in stream { received.append(event) }
        #expect(received.count == EventMulticaster.bufferSize)
        #expect(received.first == event("51"))
        #expect(received.last == event("\(overflow)"))
    }

    /// One wedged consumer must not cost the others anything.
    @Test("a stalled subscriber does not affect the others")
    func stalledSubscriberIsIsolated() async {
        let multicaster = EventMulticaster()
        let stalled = multicaster.subscribe()
        let healthy = multicaster.subscribe()

        for index in 1...(EventMulticaster.bufferSize + 10) {
            multicaster.broadcast(event("\(index)"))
        }
        multicaster.finish()

        var healthyReceived = 0
        for await _ in healthy { healthyReceived += 1 }
        var stalledReceived = 0
        for await _ in stalled { stalledReceived += 1 }

        // Both were equally starved here — the point is that neither blocked the
        // broadcaster, which returned without waiting for either.
        #expect(healthyReceived == EventMulticaster.bufferSize)
        #expect(stalledReceived == EventMulticaster.bufferSize)
    }

    @Test("subscribers are forgotten when their stream ends")
    func unsubscribesOnTermination() async {
        let multicaster = EventMulticaster()
        #expect(multicaster.subscriberCount == 0)

        let task = Task {
            for await _ in multicaster.subscribe() {}
        }
        #expect(await waitUntilCount(multicaster, is: 1))

        multicaster.finish()
        await task.value
        #expect(await waitUntilCount(multicaster, is: 0))
    }

    /// A consumer that walks away mid-stream must be dropped too, or the session leaks a
    /// continuation per window ever opened.
    @Test("a cancelled consumer is dropped")
    func cancelledConsumerIsDropped() async {
        let multicaster = EventMulticaster()
        let task = Task {
            for await _ in multicaster.subscribe() {}
        }
        #expect(await waitUntilCount(multicaster, is: 1))

        task.cancel()
        multicaster.broadcast(event("nudge"))
        await task.value
        #expect(await waitUntilCount(multicaster, is: 0))
    }

    @Test("subscribing after the session ends yields a finished stream")
    func subscribeAfterFinish() async {
        let multicaster = EventMulticaster()
        multicaster.finish()

        var received: [IRCEvent] = []
        for await event in multicaster.subscribe() { received.append(event) }
        #expect(received.isEmpty)
    }

    @Test("broadcasting with no subscribers is harmless")
    func broadcastWithoutSubscribers() {
        let multicaster = EventMulticaster()
        multicaster.broadcast(event("nobody is listening"))
        #expect(multicaster.subscriberCount == 0)
    }

    private func waitUntilCount(_ multicaster: EventMulticaster, is expected: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if multicaster.subscriberCount == expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return multicaster.subscriberCount == expected
    }
}
