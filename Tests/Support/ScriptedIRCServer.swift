import Foundation
import IRCProtocol
import IRCTransport
import Network

/// A loopback IRC server that plays a canned exchange and records what it receives.
///
/// Scripted rather than real: it has no IRC semantics at all, only "when you see a line
/// matching this, send these lines back". That is enough to drive registration, nick
/// collisions, `PING`, `ERROR` and hang-ups, and it keeps the tests reading as a
/// transcript of the exchange under test.
///
/// With no rules it is a plain recording peer, which is what the transport suite needs.
public actor ScriptedIRCServer {
    public enum ServerError: Error {
        case didNotBecomeReady
    }

    /// One scripted response.
    struct Rule {
        let matches: @Sendable (IRCMessage) -> Bool
        let responses: [String]
        /// When false the rule fires once per connection, which is how a sequence like
        /// "433 to the first NICK, welcome to the second" is expressed.
        let repeats: Bool
        var hasFired = false
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.lacuna-research.caravan.tests.server")
    private var connection: NWConnection?
    private var framer = LineFramer()
    private var rules: [Rule] = []
    private var received: [String] = []
    private var acceptedConnections = 0
    private var isReady = false

    public init() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: .any)
    }

    /// Starts listening and returns the port the kernel picked.
    public func start() async throws -> UInt16 {
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

    // MARK: - Scripting

    /// Sends `lines` whenever a received line's command matches `verb`.
    public func reply(to verb: String, with lines: [String], repeats: Bool = true) {
        reply(
            toMessagesMatching: { $0.command.isVerb(verb) },
            with: lines,
            repeats: repeats
        )
    }

    /// Sends `lines` whenever a received message matches `predicate`.
    ///
    /// Rules are tried in the order they were added and the first eligible one wins, so
    /// a one-shot rule registered first shadows a repeating rule for its first match.
    public func reply(
        toMessagesMatching predicate: @escaping @Sendable (IRCMessage) -> Bool,
        with lines: [String],
        repeats: Bool = true
    ) {
        rules.append(Rule(matches: predicate, responses: lines, repeats: repeats))
    }

    /// The usual welcome burst.
    ///
    /// - Parameters:
    ///   - after: The command that triggers it. `USER` is the last line of an ordinary
    ///     registration; a nick-collision script triggers on `NICK` instead, so the
    ///     welcome follows the *replacement* nick rather than the rejected one.
    ///   - isupport: `ISUPPORT` tokens for the 005 line.
    public func scriptWelcome(
        nick: String,
        after: String = "USER",
        serverName: String = "irc.example.org",
        network: String = "ExampleNet",
        isupport: [String] = ["CASEMAPPING=ascii", "CHANTYPES=#", "PREFIX=(ov)@+", "NICKLEN=30"],
        repeats: Bool = true
    ) {
        reply(
            to: after,
            with: [
                ":\(serverName) 001 \(nick) :Welcome to the \(network) IRC Network \(nick)",
                ":\(serverName) 002 \(nick) :Your host is \(serverName), running version caravan-test-1",
                ":\(serverName) 003 \(nick) :This server was created moments ago",
                ":\(serverName) 004 \(nick) \(serverName) caravan-test-1 iow ov",
                ":\(serverName) 005 \(nick) NETWORK=\(network) \(isupport.joined(separator: " ")) "
                    + ":are supported by this server",
            ],
            repeats: repeats
        )
    }

    // MARK: - Observation and control

    /// Lines received so far, across every connection, terminator stripped.
    public func receivedLines() -> [String] { received }

    /// How many connections have been accepted. A reconnect shows up here.
    public func connectionCount() -> Int { acceptedConnections }

    public func send(_ line: String) {
        connection?.send(content: WireDecoding.data(for: line), completion: .idempotent)
    }

    /// Hangs up on the client without stopping the listener, so it can reconnect.
    public func closeConnection() {
        connection?.cancel()
        connection = nil
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        listener.cancel()
    }

    // MARK: - Plumbing

    private func markReady() { isReady = true }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        acceptedConnections += 1
        framer = LineFramer()
        // A new connection is a new server-side session, so one-shot rules are armed
        // again — otherwise a reconnect test could never re-run registration.
        for index in rules.indices { rules[index].hasFired = false }
        connection.start(queue: queue)
        Task { await self.receiveLoop(connection) }
    }

    private func receiveLoop(_ connection: NWConnection) async {
        while !Task.isCancelled {
            guard let chunk = await nextChunk(from: connection) else { return }
            guard self.connection === connection else { return }
            for bytes in framer.push(chunk).lines {
                handle(line: WireDecoding.line(from: bytes))
            }
        }
    }

    private func handle(line: String) {
        received.append(line)
        guard let message = IRCMessage(line: line) else { return }
        guard
            let index = rules.firstIndex(where: { rule in
                (rule.repeats || !rule.hasFired) && rule.matches(message)
            })
        else { return }
        rules[index].hasFired = true
        for response in rules[index].responses {
            send(response)
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
