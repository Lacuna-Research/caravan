import Diagnostics
import IRCProtocol
import IRCTransport

/// The connection lifecycle: connect, register, stay alive, reconnect.
///
/// Owns an ``IRCConnection`` per attempt and replaces it on each reconnect, because one
/// transport instance is one connection attempt by design. Everything above this layer
/// sees a session that survives a dropped socket.
///
/// No IRC state beyond registration lives here — no channels, no users. That is prompt
/// 8's, and keeping it out is what stops this type becoming the whole client.
public actor IRCSession {
    public let configuration: SessionConfiguration
    private let trace: TraceBuffer
    private let clock = ContinuousClock()

    /// Lifecycle transitions. Never finishes: the session outlives any one connection,
    /// so a consumer subscribes once and keeps seeing reconnects.
    public nonisolated let state: AsyncStream<SessionState>
    private let stateContinuation: AsyncStream<SessionState>.Continuation

    /// Every inbound message, raw.
    ///
    /// Prompt 6 replaces this with the typed event model and its multicast; until then
    /// it is the only way for anything above to see traffic, and it deliberately shows
    /// everything, including messages this type handled itself.
    public nonisolated let inbound: AsyncStream<IRCMessage>
    private let inboundContinuation: AsyncStream<IRCMessage>.Continuation

    private var currentState: SessionState = .disconnected(reason: .notStarted)

    /// What the server said it supports. Reset per connection, refined by every 005.
    public private(set) var capabilities = ServerCapabilities()

    /// Registration data from 001–004. Refined after `.connected` is announced, since
    /// 002–004 arrive after 001; the state stream carries what was known at 001.
    public private(set) var serverInfo: ServerInfo?

    /// The nick currently in use, which may not be the configured one.
    public private(set) var currentNick: String

    /// Casemapping the server declared. Everything comparing nicks or channels must use
    /// this rather than `lowercased()`.
    public var caseMapping: IRCCaseMapping { capabilities.caseMapping }

    private var connection: IRCConnection?
    private var transportTasks: [Task<Void, Never>] = []
    private var connectDeadlineTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    /// Set by ``disconnect()`` and cleared by ``connect()``. The hard stop on reconnect.
    private var userDisconnected = false
    private var attempt = 0
    private var attemptedNicks: [String] = []

    private var lastActivity: ContinuousClock.Instant
    private var pingSentAt: ContinuousClock.Instant?

    public init(configuration: SessionConfiguration, trace: TraceBuffer) {
        self.configuration = configuration
        self.trace = trace
        self.currentNick = configuration.nick
        self.lastActivity = ContinuousClock().now

        let stateStream = AsyncStream<SessionState>.makeStream(bufferingPolicy: .unbounded)
        self.state = stateStream.stream
        self.stateContinuation = stateStream.continuation
        let inboundStream = AsyncStream<IRCMessage>.makeStream(bufferingPolicy: .unbounded)
        self.inbound = inboundStream.stream
        self.inboundContinuation = inboundStream.continuation

        stateContinuation.yield(currentState)
    }

    deinit {
        stateContinuation.finish()
        inboundContinuation.finish()
    }

    // MARK: - Public control

    /// Connects and registers. Does nothing if an attempt is already in flight.
    public func connect() async {
        guard !currentState.isActive else {
            Log.session.info("connect ignored: an attempt is already in flight")
            return
        }
        userDisconnected = false
        attempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        await startAttempt()
    }

    /// Disconnects and stays disconnected. Idempotent, and the one thing that stops the
    /// reconnect loop for good.
    public func disconnect() async {
        userDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await teardown()
        setState(.disconnected(reason: .userInitiated))
    }

    /// Sends a message, if there is a connection to send it on.
    public func send(_ message: IRCMessage) async {
        guard let connection else {
            Log.session.error("send with no connection; message dropped")
            return
        }
        await connection.send(message)
    }

    // MARK: - One attempt

    private func startAttempt() async {
        capabilities = ServerCapabilities()
        serverInfo = nil
        attemptedNicks = []
        currentNick = configuration.nick
        pingSentAt = nil
        lastActivity = clock.now

        let connection = IRCConnection(trace: trace)
        self.connection = connection
        setState(.connecting)

        transportTasks = [
            Task { [weak self] in
                for await transportState in connection.state {
                    await self?.handle(transport: transportState)
                }
            },
            Task { [weak self] in
                for await message in connection.inbound {
                    await self?.handle(message: message)
                }
            },
        ]

        // The only deadline anywhere in the stack: a refused connection leaves
        // NWConnection retrying in `.waiting` forever, and a server that accepts TCP and
        // then says nothing is equally stuck.
        connectDeadlineTask = Task { [weak self, clock, timeout = configuration.connectTimeout] in
            try? await Task.sleep(for: timeout, clock: clock)
            guard !Task.isCancelled else { return }
            await self?.connectDeadlineExpired()
        }

        Log.session.info(
            "connecting to \(self.configuration.host, privacy: .public) as \(self.currentNick, privacy: .public)"
        )
        await connection.connect(
            host: configuration.host,
            port: configuration.port,
            tls: configuration.tls
        )
    }

    private func handle(transport transportState: TransportState) async {
        // Anything arriving after the attempt was torn down belongs to a connection we
        // have already stopped caring about.
        guard connection != nil else { return }

        switch transportState {
        case .idle, .connecting:
            break
        case .ready:
            await beginRegistration()
        case .failed(let error):
            Log.session.error("transport failed: \(String(describing: error), privacy: .public)")
            await endAttempt(reason: .transportFailed(error), allowingReconnect: true)
        case .cancelled:
            await endAttempt(reason: .userInitiated, allowingReconnect: false)
        }
    }

    private func connectDeadlineExpired() async {
        switch currentState {
        case .connecting, .registering:
            Log.session.error("connect deadline expired before registration completed")
            await endAttempt(reason: .connectTimedOut, allowingReconnect: true)
        case .disconnected, .connected, .reconnecting:
            break
        }
    }

    /// Cancels this attempt's machinery and drops the connection. Does not decide what
    /// happens next.
    private func teardown() async {
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        idleTask?.cancel()
        idleTask = nil
        for task in transportTasks { task.cancel() }
        transportTasks = []

        let connection = self.connection
        self.connection = nil
        await connection?.disconnect()
    }

    /// Ends the attempt, announcing why, and reconnects unless told not to.
    ///
    /// `.disconnected(reason:)` is always announced, even when a reconnect follows
    /// immediately. `.reconnecting` carries an attempt number and a delay but no reason,
    /// so without this a consumer could see the client reconnecting and never learn what
    /// went wrong — which is exactly the question a user asks.
    private func endAttempt(reason: DisconnectReason, allowingReconnect: Bool) async {
        await teardown()
        setState(.disconnected(reason: reason))
        guard allowingReconnect, !userDisconnected else { return }
        scheduleReconnect()
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        attempt += 1
        let delay = configuration.backoff.delay(forAttempt: attempt)
        Log.session.info(
            "reconnecting (attempt \(self.attempt, privacy: .public)) in \(delay.seconds, privacy: .public)s"
        )
        setState(.reconnecting(attempt: attempt, nextAttemptIn: delay))

        reconnectTask = Task { [weak self, clock] in
            try? await Task.sleep(for: delay, clock: clock)
            guard !Task.isCancelled else { return }
            await self?.startScheduledAttempt()
        }
    }

    /// The reconnect timer firing. Re-checks everything, because the world may have
    /// moved on while it was asleep — the user may have disconnected, or connected again
    /// by hand.
    private func startScheduledAttempt() async {
        guard !userDisconnected, !currentState.isActive else { return }
        await startAttempt()
    }

    // MARK: - Registration

    private func beginRegistration() async {
        guard let connection else { return }
        if let password = configuration.password, !password.isEmpty {
            await connection.send(IRCMessage(verb: "PASS", parameters: [password]))
        }
        currentNick = configuration.nick
        attemptedNicks = [currentNick]
        await connection.send(IRCMessage(verb: "NICK", parameters: [currentNick]))
        await connection.send(
            IRCMessage(
                verb: "USER",
                parameters: [configuration.ident, "0", "*", configuration.realName]
            )
        )
        setState(.registering)
        startIdleMonitor()
    }

    /// The next nick to try after a 433, or `nil` when there is nothing left.
    ///
    /// The alt nick first, then underscores. The base is truncated so the underscore
    /// always fits: a nick already at the limit still has one variant available, where
    /// simply appending would produce an over-long nick and no candidate at all.
    ///
    /// `NICKLEN` here is necessarily the RFC default unless the caller knows better,
    /// since `ISUPPORT` arrives *after* 001 and 433 arrives before it. The configured
    /// nick's own length is taken as evidence of what the server accepts — it answered
    /// "in use", not "erroneous".
    private func nextNickCandidate() -> String? {
        if let alt = configuration.altNick, !alt.isEmpty, !attemptedNicks.contains(alt) {
            return alt
        }
        let limit = max(capabilities.nickLength, configuration.nick.count)
        guard limit > 1, let base = attemptedNicks.last else { return nil }
        let candidate = String(base.prefix(limit - 1)) + "_"
        // Truncation converges: once it stops producing a new nick, there is nothing
        // left to try, and that is also what bounds this loop.
        return attemptedNicks.contains(candidate) ? nil : candidate
    }

    private func handleNickInUse() async {
        guard case .registering = currentState else {
            // A 433 outside registration answers a /nick the user typed. Prompt 9 owns
            // the response to that; here it is just another numeric.
            return
        }
        guard let candidate = nextNickCandidate() else {
            await endAttempt(
                reason: .registrationFailed(
                    "every nickname was already in use: \(attemptedNicks.joined(separator: ", "))"
                ),
                allowingReconnect: false
            )
            return
        }
        currentNick = candidate
        attemptedNicks.append(candidate)
        await connection?.send(IRCMessage(verb: "NICK", parameters: [candidate]))
    }

    // MARK: - Inbound

    private func handle(message: IRCMessage) async {
        guard connection != nil else { return }

        // Any traffic at all proves the connection is alive, which is the whole question
        // the idle monitor is asking.
        lastActivity = clock.now
        pingSentAt = nil

        inboundContinuation.yield(message)

        if message.command.isVerb("PING") {
            await connection?.send(
                IRCMessage(verb: "PONG", parameters: [message.parameters.last ?? ""])
            )
            return
        }
        if message.command.isVerb("ERROR") {
            let reason = message.parameters.last ?? "no reason given"
            Log.session.error("server sent ERROR")
            await endAttempt(reason: .serverError(reason), allowingReconnect: true)
            return
        }

        switch message.command.numericCode {
        case 1: handleWelcome(message)
        case 2: serverInfo?.hostInfo = message.parameters.last
        case 3: serverInfo?.created = message.parameters.last
        case 4: handleMyInfo(message)
        case 5: capabilities.apply(tokens: ServerCapabilities.tokens(inISUPPORT: message))
        case 433: await handleNickInUse()
        case 432:
            // Erroneous nickname: retrying with an underscore cannot help, since the
            // server is rejecting the shape of the name rather than its availability.
            await endAttempt(
                reason: .registrationFailed(
                    "the server rejected the nickname \(currentNick) as invalid"
                ),
                allowingReconnect: false
            )
        default:
            break
        }
    }

    private func handleWelcome(_ message: IRCMessage) {
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        attempt = 0

        currentNick = message.parameters.first ?? currentNick
        var info = ServerInfo(nick: currentNick)
        info.welcome = message.parameters.count > 1 ? message.parameters.last : nil
        if case .server(let name)? = message.source { info.serverName = name }
        serverInfo = info

        Log.session.info("registered as \(self.currentNick, privacy: .public)")
        setState(.connected(info))
    }

    /// 004 is `<client> <server> <version> <user modes> <channel modes>`.
    private func handleMyInfo(_ message: IRCMessage) {
        let parameters = message.parameters
        guard parameters.count >= 3 else { return }
        serverInfo?.serverName = parameters[1]
        serverInfo?.version = parameters[2]
        serverInfo?.userModes = parameters.count > 3 ? parameters[3] : nil
        serverInfo?.channelModes = parameters.count > 4 ? parameters[4] : nil
    }

    // MARK: - Idle detection

    private func startIdleMonitor() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            await self?.idleMonitor()
        }
    }

    /// Sends a `PING` after silence, and gives up if it goes unanswered.
    ///
    /// Sleeps to the next deadline rather than polling, and re-evaluates afterwards:
    /// traffic that arrived meanwhile has moved the deadline forward, so the loop simply
    /// sleeps again.
    private func idleMonitor() async {
        while !Task.isCancelled {
            let deadline =
                pingSentAt.map { $0 + configuration.idleResponseTimeout }
                ?? lastActivity + configuration.idleInterval

            if clock.now < deadline {
                try? await Task.sleep(until: deadline, clock: clock)
                continue
            }
            guard !Task.isCancelled else { return }

            if pingSentAt != nil {
                Log.session.error("no response to our PING; treating the connection as dead")
                await endAttempt(reason: .timedOut, allowingReconnect: true)
                return
            }
            pingSentAt = clock.now
            await connection?.send(IRCMessage(verb: "PING", parameters: [configuration.host]))
        }
    }

    // MARK: - State

    private func setState(_ newState: SessionState) {
        currentState = newState
        stateContinuation.yield(newState)
    }
}
