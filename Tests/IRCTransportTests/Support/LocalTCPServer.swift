import Foundation
import Network

@testable import IRCTransport

/// A minimal TCP peer on loopback: accepts one connection, frames what it receives into
/// lines, and writes raw lines back.
///
/// Deliberately not an IRC server. Prompt 5 needs a *scriptable* one that plays a canned
/// exchange and asserts on registration; this only has to prove that bytes make the
/// round trip, and keeping it dumb keeps this test file about the transport.
actor LocalTCPServer {
    enum ServerError: Error {
        case didNotBecomeReady
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.lacuna-research.caravan.tests.server")
    private var connection: NWConnection?
    private var framer = LineFramer()
    private var received: [String] = []
    private var isReady = false

    init() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: .any)
    }

    /// Starts listening and returns the port the kernel picked.
    func start() async throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { await self?.markReady() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: queue)

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if isReady, let port = listener.port?.rawValue { return port }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ServerError.didNotBecomeReady
    }

    /// Lines received so far, terminator stripped.
    func receivedLines() -> [String] { received }

    func send(_ line: String) {
        connection?.send(content: WireDecoding.data(for: line), completion: .idempotent)
    }

    /// Hangs up on the client without stopping the listener.
    func closeConnection() {
        connection?.cancel()
        connection = nil
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener.cancel()
    }

    private func markReady() { isReady = true }

    private func accept(_ connection: NWConnection) {
        guard self.connection == nil else {
            connection.cancel()
            return
        }
        self.connection = connection
        connection.start(queue: queue)
        Task { await self.receiveLoop(connection) }
    }

    /// Same shape as the transport's own loop, and for the same reason: reads have to
    /// reach the framer in the order they arrived.
    private func receiveLoop(_ connection: NWConnection) async {
        while !Task.isCancelled {
            guard let chunk = await nextChunk(from: connection) else { return }
            received += framer.push(chunk).lines.map { WireDecoding.line(from: $0) }
        }
    }

    /// One read, or `nil` once nothing more can arrive.
    private func nextChunk(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1024
            ) { data, _, isComplete, error in
                continuation.resume(returning: (isComplete || error != nil) ? nil : data)
            }
        }
    }
}
