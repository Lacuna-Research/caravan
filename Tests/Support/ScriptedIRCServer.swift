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
    /// Every client currently attached. Several at once is the bouncer case.
    private var connections: [NWConnection] = []
    private var framers: [ObjectIdentifier: LineFramer] = [:]
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
            with: Self.welcomeLines(
                nick: nick,
                serverName: serverName,
                network: network,
                isupport: isupport
            ),
            repeats: repeats
        )
    }

    /// The welcome burst as lines, for a test that triggers it on something other than a
    /// bare verb — capability negotiation ends with `CAP END`, and every other `CAP` line
    /// has to be answered differently.
    public static func welcomeLines(
        nick: String,
        serverName: String = "irc.example.org",
        network: String = "ExampleNet",
        isupport: [String] = ["CASEMAPPING=ascii", "CHANTYPES=#", "PREFIX=(ov)@+", "NICKLEN=30"]
    ) -> [String] {
        [
            ":\(serverName) 001 \(nick) :Welcome to the \(network) IRC Network \(nick)",
            ":\(serverName) 002 \(nick) :Your host is \(serverName), running version caravan-test-1",
            ":\(serverName) 003 \(nick) :This server was created moments ago",
            ":\(serverName) 004 \(nick) \(serverName) caravan-test-1 iow ov",
            ":\(serverName) 005 \(nick) NETWORK=\(network) \(isupport.joined(separator: " ")) "
                + ":are supported by this server",
        ]
    }

    /// Answers `CAP LS` and `CAP REQ`, then welcomes on `CAP END`.
    ///
    /// The whole negotiation in one call, because every capability test needs the same
    /// four-line exchange around whatever it is actually checking.
    ///
    /// - Parameters:
    ///   - offering: The `CAP LS` token list, `name=value` and all.
    ///   - acknowledging: What to `ACK`. `nil` acknowledges exactly what was requested,
    ///     which is what a cooperative server does.
    ///   - refusing: Send a `NAK` instead of an `ACK`.
    ///   - welcomingOnEnd: Whether `CAP END` produces the welcome burst. A SASL test that
    ///     fails authentication never gets there.
    public func scriptCapabilityNegotiation(
        nick: String,
        offering: [String],
        acknowledging: [String]? = nil,
        refusing: Bool = false,
        welcomingOnEnd: Bool = true
    ) {
        reply(
            toMessagesMatching: { $0.command.isVerb("CAP") && $0.parameters.first == "LS" },
            with: [":irc.example.org CAP * LS :\(offering.joined(separator: " "))"]
        )
        if welcomingOnEnd {
            reply(
                toMessagesMatching: { $0.command.isVerb("CAP") && $0.parameters.first == "END" },
                with: Self.welcomeLines(nick: nick)
            )
        }
        // The `ACK` echoes the request, so it is built from the line that arrived rather
        // than from a fixed list — which is also what makes `acknowledging: nil` mean
        // "whatever they asked for".
        acknowledgement = Acknowledgement(
            nick: nick,
            fixed: acknowledging,
            isRefusal: refusing
        )
    }

    private struct Acknowledgement {
        let nick: String
        let fixed: [String]?
        let isRefusal: Bool
    }

    private var acknowledgement: Acknowledgement?

    // MARK: - Observation and control

    /// Lines received so far, across every connection, terminator stripped.
    public func receivedLines() -> [String] { received }

    /// How many connections have been accepted. A reconnect shows up here.
    public func connectionCount() -> Int { acceptedConnections }

    /// Writes a line to **every** connected client.
    ///
    /// Does nothing if no client has been accepted yet, which is a real hazard: a client
    /// reaches `.ready` as soon as TCP completes, while accepting here still has an
    /// actor hop to make. Wait for ``connectionCount()`` before sending unprompted —
    /// scripted replies are immune, since a rule can only fire on a line that arrived.
    ///
    /// **Broadcast**, for a line the server volunteers rather than one it is answering.
    /// A bouncer holds a control connection *and* one per bound network at the same time,
    /// and a `BOUNCER NETWORK` notification has to reach the control connection even
    /// though the bound ones connected after it.
    ///
    /// Scripted *replies* do not come through here — they go to whoever asked, via
    /// ``send(_:to:)``. See the note on `handle(line:from:)` for what broadcasting them
    /// instead cost.
    public func send(_ line: String) {
        let data = WireDecoding.data(for: line)
        for connection in connections {
            connection.send(content: data, completion: .idempotent)
        }
    }

    /// Writes a line to one client — an answer going back to whoever asked.
    private func send(_ line: String, to connection: NWConnection) {
        connection.send(content: WireDecoding.data(for: line), completion: .idempotent)
    }

    /// Hangs up on every client without stopping the listener, so they can reconnect.
    public func closeConnection() {
        for connection in connections { connection.cancel() }
        connections = []
        framers = [:]
    }

    public func stop() {
        closeConnection()
        listener.cancel()
    }

    // MARK: - Plumbing

    private func markReady() { isReady = true }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        // A framer per connection: two clients' bytes interleave on the way in, and one
        // shared framer would splice a line from each into nonsense.
        framers[ObjectIdentifier(connection)] = LineFramer()
        acceptedConnections += 1
        // A new connection is a new server-side session, so one-shot rules are armed
        // again — otherwise a reconnect test could never re-run registration.
        for index in rules.indices { rules[index].hasFired = false }
        connection.start(queue: queue)
        Task { await self.receiveLoop(connection) }
    }

    private func receiveLoop(_ connection: NWConnection) async {
        let key = ObjectIdentifier(connection)
        while !Task.isCancelled {
            guard let chunk = await nextChunk(from: connection) else { break }
            guard connections.contains(where: { $0 === connection }) else { return }
            let lines = framers[key]?.push(chunk).lines ?? []
            for bytes in lines {
                handle(line: WireDecoding.line(from: bytes), from: connection)
            }
        }
        connections.removeAll { $0 === connection }
        framers.removeValue(forKey: key)
    }

    /// Handles one line, **replying only to the client that sent it.**
    ///
    /// A scripted reply is an answer, and an answer goes to whoever asked. Broadcasting
    /// them instead — which this did briefly — means a welcome burst triggered by one
    /// client's `CAP END` lands on every other client too. With a bouncer that is not a
    /// cosmetic difference: the control connection sees a second `001`, re-runs
    /// registration and re-sends `BOUNCER LISTNETWORKS`, which re-adds a network the test
    /// had just removed. That produced a genuine-looking product bug that was entirely
    /// this harness's doing.
    private func handle(line: String, from connection: NWConnection) {
        received.append(line)
        guard let message = IRCMessage(line: line) else { return }
        if let acknowledgement, message.command.isVerb("CAP"),
            message.parameters.first == "REQ"
        {
            let requested = message.parameters.count > 1 ? message.parameters[1] : ""
            let granted = acknowledgement.fixed?.joined(separator: " ") ?? requested
            let verb = acknowledgement.isRefusal ? "NAK" : "ACK"
            send(
                ":irc.example.org CAP \(acknowledgement.nick) \(verb) :\(granted)",
                to: connection
            )
        }
        guard
            let index = rules.firstIndex(where: { rule in
                (rule.repeats || !rule.hasFired) && rule.matches(message)
            })
        else { return }
        rules[index].hasFired = true
        for response in rules[index].responses {
            send(response, to: connection)
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
