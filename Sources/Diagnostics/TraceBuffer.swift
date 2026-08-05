import Synchronization

/// One line of wire traffic, already redacted.
public struct TraceEvent: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case inbound
        case outbound
    }

    public let direction: Direction

    /// The line as it will be shown. Redaction happened before this was stored, so a
    /// credential is never resident here.
    public let line: String

    /// Monotonic, so elapsed time between events stays correct across clock changes.
    public let timestamp: ContinuousClock.Instant

    public init(direction: Direction, line: String, timestamp: ContinuousClock.Instant) {
        self.direction = direction
        self.line = line
        self.timestamp = timestamp
    }
}

/// A bounded, thread-safe ring of recent wire traffic.
///
/// Always on, so `/debug -i` can show what happened *before* debugging was switched
/// on — the case that matters, since problems are noticed after they occur. Bounded so
/// an always-on buffer cannot grow without limit, and in memory only so it disappears
/// when the process does.
///
/// Redaction is applied here, on insert. Callers pass raw lines and this stores
/// redacted ones; there is no way to put an unredacted line in.
public final class TraceBuffer: Sendable {
    private struct State {
        var storage: [TraceEvent?]
        var next: Int = 0
        var count: Int = 0
    }

    public let capacity: Int
    private let state: Mutex<State>
    private let clock = ContinuousClock()

    /// - Parameter capacity: Maximum retained events. A few thousand lines covers a
    ///   busy channel for long enough to be useful without meaningful memory cost.
    public init(capacity: Int = 4096) {
        precondition(capacity > 0, "TraceBuffer capacity must be positive")
        self.capacity = capacity
        self.state = Mutex(State(storage: Array(repeating: nil, count: capacity)))
    }

    /// Redacts `line` and appends it, evicting the oldest event when full.
    public func record(_ direction: TraceEvent.Direction, line: String) {
        let event = TraceEvent(
            direction: direction,
            line: Redactor.redact(line),
            timestamp: clock.now
        )
        state.withLock { state in
            state.storage[state.next] = event
            state.next = (state.next + 1) % capacity
            state.count = Swift.min(state.count + 1, capacity)
        }
    }

    /// Retained events, oldest first.
    public func snapshot() -> [TraceEvent] {
        state.withLock { state in
            guard state.count > 0 else { return [] }
            let start = (state.next - state.count + capacity) % capacity
            return (0..<state.count).compactMap { state.storage[(start + $0) % capacity] }
        }
    }

    /// Number of retained events.
    public var count: Int {
        state.withLock { $0.count }
    }

    public func clear() {
        state.withLock { state in
            state.storage = Array(repeating: nil, count: capacity)
            state.next = 0
            state.count = 0
        }
    }
}
