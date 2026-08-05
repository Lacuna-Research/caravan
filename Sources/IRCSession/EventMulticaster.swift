import Synchronization

/// Fans one event stream out to any number of independent consumers.
///
/// A single `AsyncStream` cannot do this: it has one iterator, and two consumers sharing
/// it would each see an arbitrary half of the events. The UI, the logger and later the
/// scripting engine all need the whole feed.
///
/// **What happens when a consumer stalls.** Each subscriber gets its own buffer of
/// ``bufferSize`` events. When it fills, that subscriber's *oldest* unread events are
/// dropped — `bufferingNewest` — and nothing else is affected: the session never blocks,
/// and other subscribers do not lose anything. A stalled UI therefore skips ahead to
/// what is happening now rather than falling permanently behind, which is the right
/// trade for a chat window. Anything needing a complete record should read the
/// `TraceBuffer`, which is bounded but never silently partial in the middle.
///
/// Not an actor: a subscriber must be able to call ``subscribe()`` synchronously, and
/// broadcasting has to work from wherever the session happens to be.
final class EventMulticaster: Sendable {
    /// Events buffered per subscriber. A MOTD burst is a few hundred lines, so this
    /// absorbs one comfortably while staying small enough that a wedged consumer cannot
    /// grow it without bound.
    static let bufferSize = 1024

    private struct State {
        var subscribers: [Int: AsyncStream<IRCEvent>.Continuation] = [:]
        var nextID = 0
        var isFinished = false
    }

    private let state = Mutex(State())

    /// A stream carrying every event from now on. Each caller gets its own.
    func subscribe() -> AsyncStream<IRCEvent> {
        let (stream, continuation) = AsyncStream<IRCEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferSize)
        )
        let identifier = state.withLock { state -> Int? in
            guard !state.isFinished else { return nil }
            state.nextID += 1
            state.subscribers[state.nextID] = continuation
            return state.nextID
        }
        guard let identifier else {
            // Subscribing to a finished session yields an empty, already-ended stream
            // rather than one that waits forever for events that cannot come.
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.remove(identifier)
        }
        return stream
    }

    /// Delivers `event` to every current subscriber.
    func broadcast(_ event: IRCEvent) {
        // Continuations are copied out before yielding. `yield` can run a termination
        // handler, which takes this same lock, so holding it across the call would be a
        // deadlock waiting for a subscriber to go away at the wrong moment.
        let continuations = state.withLock { Array($0.subscribers.values) }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    /// Ends every stream. Subscribers' `for await` loops finish.
    func finish() {
        let continuations = state.withLock { state -> [AsyncStream<IRCEvent>.Continuation] in
            state.isFinished = true
            let existing = Array(state.subscribers.values)
            state.subscribers.removeAll()
            return existing
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Subscriber count. Exists for the tests that assert unsubscription actually
    /// happens — a multicaster that never forgets a consumer is a leak.
    var subscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }

    private func remove(_ identifier: Int) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: identifier) }
    }
}
