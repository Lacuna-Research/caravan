import Foundation
import IRCProtocol

@testable import IRCTransport

/// Polls until `condition` holds, or gives up.
///
/// The transport's work lands through dispatch queues and detached tasks, so the tests
/// wait on observable outcomes rather than on a fixed sleep. Polling keeps a passing
/// test fast — the timeout only matters when something is already broken.
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Drains an `AsyncStream` into an array a test can assert against.
actor StreamLog<Element: Sendable> {
    private var elements: [Element] = []

    /// Consumes the stream until it finishes. The returned task ends on its own when the
    /// connection reaches a terminal state.
    @discardableResult
    nonisolated func drain(_ stream: AsyncStream<Element>) -> Task<Void, Never> {
        Task { [self] in
            for await element in stream {
                await append(element)
            }
        }
    }

    private func append(_ element: Element) { elements.append(element) }

    func snapshot() -> [Element] { elements }
    func count() -> Int { elements.count }
}
