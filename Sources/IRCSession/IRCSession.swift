import Diagnostics
import IRCProtocol
import IRCTransport

/// The connection lifecycle: connect, register, stay alive, reconnect.
///
/// Owns an ``IRCConnection`` per attempt and replaces it on each reconnect, because one
/// transport instance is one connection attempt by design. Everything above this layer
/// sees a session that survives a dropped socket.
///
/// Channel and membership state lives here too, in a ``ChannelRoster``, and leaves only
/// as immutable ``Channel`` snapshots on ``IRCEvent/channelChanged(_:)``. Keeping the
/// transitions on one side of the actor is what stops every view that draws a nick list
/// from reimplementing them.
public actor IRCSession {
    public let configuration: SessionConfiguration
    private let trace: TraceBuffer
    private let clock = ContinuousClock()

    private let multicaster = EventMulticaster()

    private var currentState: SessionState = .disconnected(reason: .notStarted)

    /// What the server said it supports. Reset per connection, refined by every 005.
    public private(set) var capabilities = ServerCapabilities()

    /// What `CAP` negotiation settled on. Reset per connection, like ``capabilities``.
    ///
    /// The two are different questions with confusingly similar names: `ISUPPORT` is what
    /// the *server* does, negotiated capabilities are what this connection agreed to.
    public private(set) var negotiated = NegotiatedCapabilities()

    /// Registration data from 001–004. Refined after `.registered` is emitted, since
    /// 002–004 arrive after 001 and nothing marks the end of that burst.
    public private(set) var serverInfo: ServerInfo?

    /// The nick currently in use, which may not be the configured one.
    public private(set) var currentNick: String

    /// Casemapping the server declared. Everything comparing nicks or channels must use
    /// this rather than `lowercased()`.
    public var caseMapping: IRCCaseMapping { capabilities.caseMapping }

    /// Channels and their members. Snapshots leave here; the state does not.
    private var roster: ChannelRoster

    /// Every channel with a buffer, in join order.
    public var channels: [Channel] { roster.snapshots }

    /// One channel, or `nil` when we have no buffer for it.
    public func channel(named name: IRCChannelName) -> Channel? { roster[name] }

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

    /// Where `CAP` negotiation has got to on this attempt.
    ///
    /// Linear, and it matters that it is: registration is held open by the server until we
    /// send `CAP END`, so an attempt that loses track of this phase is an attempt that
    /// hangs until the connect deadline rather than failing.
    private enum CapabilityPhase {
        case notStarted
        /// `CAP LS` sent, collecting what may be several lines of it.
        case listing
        /// `CAP REQ` sent, waiting for the `ACK` or `NAK`.
        case requesting
        /// A SASL exchange is in flight; `CAP END` waits for it.
        case authenticating
        /// `CAP END` sent, or the server turned out not to speak `CAP` at all.
        case ended
    }

    private var capabilityPhase: CapabilityPhase = .notStarted
    private var sasl: SASLExchange?
    private var saslChunks = SASLWire.Accumulator()

    /// NickServ credentials waiting for registration to finish, whether they were the
    /// configured method or the fallback for a server with no SASL.
    private var pendingIdentify: (account: String, password: String)?

    /// Upstream networks, when this is the unbound connection to a bouncer.
    ///
    /// In the order the bouncer first named them, so the tree does not reshuffle every
    /// time one network's state changes.
    public private(set) var bouncerNetworks: [BouncerNetwork] = []

    /// The trust evaluator and client certificate, carried across reconnects because each
    /// attempt builds a fresh ``IRCConnection`` and both belong to the *identity* rather
    /// than to any one socket.
    private let credentials: TLSCredentials

    public init(
        configuration: SessionConfiguration,
        trace: TraceBuffer,
        credentials: TLSCredentials = TLSCredentials()
    ) {
        self.configuration = configuration
        self.trace = trace
        self.credentials = credentials
        self.currentNick = configuration.nick
        self.lastActivity = ContinuousClock().now
        self.roster = ChannelRoster(ownNick: configuration.nick)
    }

    deinit {
        multicaster.finish()
    }

    /// A stream of every event from now on. Each caller gets its own.
    ///
    /// Subscribe before calling ``connect()``: events are not replayed, so anything
    /// emitted before the call is not seen. The stream lives as long as the session,
    /// across any number of reconnects, and its buffering is described on
    /// ``EventMulticaster``.
    public nonisolated func events() -> AsyncStream<IRCEvent> {
        multicaster.subscribe()
    }

    /// The current lifecycle state, for a caller that needs it without waiting for the
    /// next transition.
    public var state: SessionState { currentState }

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
            // Told to the user, not just to the log: typing into a window that is not
            // connected must produce an answer rather than silence.
            emit(.clientError("not connected: \(message.command.wireForm) was not sent"))
            return
        }
        await connection.send(message)
    }

    /// Closes a channel buffer, parting the channel if we are still in it.
    ///
    /// The asymmetry with `PART` is deliberate and is the whole of the buffer-lifecycle
    /// invariant: **membership never outlives its buffer, but a buffer may outlive
    /// membership.** Closing is the only thing that removes a channel from the roster, so
    /// there is never a channel we are joined to with nowhere to see it.
    public func closeChannel(_ name: IRCChannelName) async {
        guard let channel = roster[name] else { return }
        if channel.isJoined, connection != nil {
            await send(IRCMessage(verb: "PART", parameters: [channel.name.raw]))
        }
        roster.remove(name)
        multicaster.broadcast(.channelClosed(name))
    }

    // MARK: - One attempt

    private func startAttempt() async {
        capabilities = ServerCapabilities()
        negotiated = NegotiatedCapabilities()
        capabilityPhase = .notStarted
        sasl = nil
        saslChunks = SASLWire.Accumulator()
        pendingIdentify = nil
        bouncerNetworks = []
        serverInfo = nil
        attemptedNicks = []
        setCurrentNick(configuration.nick)
        // Channels survive a reconnect — nothing vanishes because wifi dropped — but
        // their keys do not: `ISUPPORT` has just been reset, and a name folded under the
        // old server's casemapping would no longer match itself.
        roster.updateCapabilities(capabilities)
        pingSentAt = nil
        lastActivity = clock.now

        let connection = IRCConnection(trace: trace, credentials: credentials)
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

        // The only deadline anywhere in the stack: an unroutable address leaves
        // NWConnection in `.connecting` indefinitely, and a server that accepts TCP and
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
        case .failed(.trustRefused):
            // A refused certificate is a decision, not a fault. Reconnecting would present
            // the same trust question again a few seconds after the user declined it, and
            // again after that — a dialog that will not take no for an answer.
            Log.session.error("the server's TLS certificate was not trusted")
            await endAttempt(reason: .trustRefused, allowingReconnect: false)
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
        // **First line on the wire, before `PASS`.** The server holds 001 back until
        // `CAP END`, and asking after `USER` races a server that answers immediately.
        // `302` asks for the 3.2 form, which carries `name=value` and implies `cap-notify`.
        capabilityPhase = .listing
        await connection.send(IRCMessage(verb: "CAP", parameters: ["LS", "302"]))

        if let password = configuration.password, !password.isEmpty {
            await connection.send(IRCMessage(verb: "PASS", parameters: [password]))
        }
        setCurrentNick(configuration.nick)
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
        setCurrentNick(candidate)
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

        // 005 is applied before anything is translated, so the line that announces
        // CHANTYPES or CASEMAPPING is not itself interpreted under the old values.
        if message.command.numericCode == 5 {
            capabilities.apply(tokens: ServerCapabilities.tokens(inISUPPORT: message))
            roster.updateCapabilities(capabilities)
        }

        // Emission comes before the session acts on the message, so `.raw` is first for
        // every line — including the ones handled entirely down here, like PING.
        for event in EventTranslator.events(for: message, capabilities: capabilities) {
            // Our own `NICK` moves the session's idea of who we are. The roster tracks it
            // separately, since it is what tells a self-join from anyone else's.
            if case .nickChanged(let who, let newNick) = event,
                capabilities.caseMapping.equal(who.nick ?? "", currentNick)
            {
                currentNick = newNick
                serverInfo?.nick = newNick
            }
            emit(event)
        }

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
        if message.command.isVerb("CAP") {
            await handleCapability(message)
            return
        }
        if message.command.isVerb("AUTHENTICATE") {
            await handleAuthenticate(message)
            return
        }
        if message.command.isVerb("BOUNCER") {
            handleBouncer(message)
            return
        }
        if message.command.isVerb("JOIN") {
            await requestHistoryIfOurJoin(message)
        }

        switch message.command.numericCode {
        case 1: await handleWelcome(message)
        case 2: serverInfo?.hostInfo = message.parameters.last
        case 3: serverInfo?.created = message.parameters.last
        case 4: handleMyInfo(message)
        case 5: break  // Already applied above.
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
        case 903, 907:
            // SASL succeeded, or we were already authenticated. Either way registration is
            // free to finish. 907 is not an error: it answers a second `AUTHENTICATE` on a
            // connection that is already logged in.
            await finishAuthentication()
        case 902, 904, 905, 906:
            await failAuthentication(
                message.parameters.last ?? "the server refused the credentials"
            )
        default:
            break
        }
    }

    // MARK: - Capability negotiation

    private func handleCapability(_ message: IRCMessage) async {
        guard let command = CapabilityCommand(message: message) else { return }
        switch command.subcommand {
        case .ls:
            negotiated.advertise(command.tokens)
            // A `*` means another `LS` line follows; deciding what to ask for before the
            // list is complete would ask for a subset of what is on offer.
            guard !command.isContinued else { return }
            await requestCapabilities()

        case .new:
            // `cap-notify`: something appeared mid-session. Ask for it if we can use it,
            // and say so either way.
            negotiated.advertise(command.tokens)
            let wanted = wantedCapabilities(among: command.tokens.map(\.name))
            guard !wanted.isEmpty else {
                emit(.capabilitiesChanged(negotiated))
                return
            }
            await sendRequest(for: wanted)

        case .del:
            negotiated.withdraw(command.tokens)
            emit(.capabilitiesChanged(negotiated))

        case .ack:
            negotiated.acknowledge(command.tokens)
            await capabilitiesAcknowledged()

        case .nak:
            // A `REQ` is atomic: a `NAK` means nothing in it was enabled. Loud rather than
            // silent, because a server that refuses what it advertised is worth knowing
            // about when something downstream then behaves oddly.
            let refused = command.tokens.map(\.name).joined(separator: " ")
            Log.session.error("server refused capabilities: \(refused, privacy: .public)")
            emit(.clientNotice("the server refused these capabilities: \(refused)"))
            await endCapabilityNegotiation()

        case .list:
            negotiated.replaceEnabled(command.tokens)
            emit(.capabilitiesChanged(negotiated))
        }
    }

    /// Everything we know how to use, that this server offers, that is not already on.
    private func wantedCapabilities(among names: [String]? = nil) -> [ClientCapability] {
        ClientCapability.allCases.filter { capability in
            if let names, !names.contains(capability.rawValue) { return false }
            guard negotiated.isAvailable(capability), !negotiated.isEnabled(capability) else {
                return false
            }
            guard capability == .sasl else { return true }
            // SASL is asked for only when it will be used, and only when the server offers
            // the mechanism actually configured. Requesting it and then having nothing to
            // say leaves the server waiting on an `AUTHENTICATE` that is not coming.
            guard case .sasl(let mechanism, _, _) = configuration.authentication else {
                return false
            }
            return negotiated.saslMechanisms.contains(mechanism.rawValue)
        }
    }

    private func requestCapabilities() async {
        let wanted = wantedCapabilities()
        guard !wanted.isEmpty else {
            await endCapabilityNegotiation()
            return
        }
        capabilityPhase = .requesting
        await sendRequest(for: wanted)
    }

    private func sendRequest(for capabilities: [ClientCapability]) async {
        await connection?.send(
            IRCMessage(
                verb: "CAP",
                parameters: ["REQ", capabilities.map(\.rawValue).joined(separator: " ")]
            )
        )
    }

    private func capabilitiesAcknowledged() async {
        guard capabilityPhase == .requesting else {
            // A `CAP NEW` acknowledged after registration. There is no negotiation left to
            // end, only news to report.
            emit(.capabilitiesChanged(negotiated))
            return
        }
        guard negotiated.isEnabled(.sasl),
            case .sasl(let mechanism, let account, let password) = configuration.authentication
        else {
            await endCapabilityNegotiation()
            return
        }
        capabilityPhase = .authenticating
        sasl = SASLExchange(mechanism: mechanism, account: account, password: password)
        saslChunks = SASLWire.Accumulator()
        Log.session.info(
            "authenticating with SASL \(mechanism.rawValue, privacy: .public)"
        )
        await connection?.send(IRCMessage(verb: "AUTHENTICATE", parameters: [mechanism.rawValue]))
    }

    /// Sends `CAP END`, once, and works out whether NickServ has to stand in for SASL.
    ///
    /// `BOUNCER BIND` goes out just before it, which is the only window the extension
    /// allows: the capability must already be acknowledged, and binding after registration
    /// completes is refused with `REGISTRATION_IS_COMPLETED`.
    private func endCapabilityNegotiation() async {
        guard capabilityPhase != .ended else { return }
        capabilityPhase = .ended

        if let networkID = configuration.bouncerNetworkID {
            guard negotiated.isEnabled(.bouncerNetworks) else {
                // Binding is the whole purpose of this connection. Carrying on would
                // register us against the bouncer itself and silently show the wrong
                // network's traffic under this network's name.
                await endAttempt(
                    reason: .registrationFailed(
                        "the server does not support soju.im/bouncer-networks, so network "
                            + "\(networkID) cannot be reached"
                    ),
                    allowingReconnect: false
                )
                return
            }
            await connection?.send(IRCMessage(verb: "BOUNCER", parameters: ["BIND", networkID]))
        }

        switch configuration.authentication {
        case .none:
            break
        case .nickServ(let account, let password):
            pendingIdentify = (account, password)
        case .sasl:
            if !negotiated.isEnabled(.sasl),
                let fallback = configuration.authentication.nickServFallback
            {
                pendingIdentify = fallback
                emit(
                    .clientNotice(
                        "this server does not offer SASL; identifying to NickServ after registration"
                    )
                )
            }
        }

        emit(.capabilitiesChanged(negotiated))
        await connection?.send(IRCMessage(verb: "CAP", parameters: ["END"]))
    }

    // MARK: - Authentication

    private func handleAuthenticate(_ message: IRCMessage) async {
        guard var exchange = sasl else { return }
        // A parameterless `AUTHENTICATE` is the empty challenge, which is what a server
        // sends to say "go ahead" at the start of every mechanism.
        switch saslChunks.push(message.parameters.first ?? SASLWire.empty) {
        case .incomplete:
            return
        case .undecodable:
            await abortAuthentication("the server's SASL challenge was not valid base64")
        case .complete(let challenge):
            do {
                let response = try exchange.respond(to: challenge)
                sasl = exchange
                for chunk in SASLWire.chunks(for: response) {
                    await connection?.send(IRCMessage(verb: "AUTHENTICATE", parameters: [chunk]))
                }
            } catch {
                await abortAuthentication(String(describing: error))
            }
        }
    }

    /// Tells the server we are giving up on the exchange, then fails the attempt.
    ///
    /// The `AUTHENTICATE *` matters: without it the server holds the connection in a
    /// half-finished exchange until its own timeout, which is a worse citizen than saying
    /// so and leaving.
    private func abortAuthentication(_ detail: String) async {
        await connection?.send(IRCMessage(verb: "AUTHENTICATE", parameters: ["*"]))
        await failAuthentication(detail)
    }

    private func failAuthentication(_ detail: String) async {
        guard capabilityPhase == .authenticating else { return }
        sasl = nil
        Log.session.error("SASL authentication failed")
        await endAttempt(reason: .authenticationFailed(detail), allowingReconnect: false)
    }

    private func finishAuthentication() async {
        guard capabilityPhase == .authenticating else { return }
        sasl = nil
        await endCapabilityNegotiation()
    }

    private func handleWelcome(_ message: IRCMessage) async {
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        attempt = 0

        currentNick = message.parameters.first ?? currentNick
        var info = ServerInfo(nick: currentNick)
        info.welcome = message.parameters.count > 1 ? message.parameters.last : nil
        if case .server(let name)? = message.source { info.serverName = name }
        serverInfo = info

        roster.setOwnNick(currentNick)
        Log.session.info("registered as \(self.currentNick, privacy: .public)")
        emit(.registered(info))
        setState(.connected(info))

        // A server that ignored `CAP LS` entirely gets here with negotiation still open.
        // Marking it ended is what stops a later `CAP` line producing a stray `CAP END` on
        // a connection that is already registered.
        capabilityPhase = .ended
        await identifyToNickServIfNeeded()
        await listBouncerNetworksIfNeeded()
    }

    /// Asks a bouncer what it is holding, on the one connection allowed to ask.
    ///
    /// Only the *unbound* connection may enumerate: a bound one is talking to an upstream
    /// network, which knows nothing about the bouncer's other networks.
    private func listBouncerNetworksIfNeeded() async {
        guard configuration.bouncerNetworkID == nil, negotiated.isEnabled(.bouncerNetworks) else {
            return
        }
        await connection?.send(IRCMessage(verb: "BOUNCER", parameters: ["LISTNETWORKS"]))
    }

    // MARK: - Backfill

    /// Asks for what was said in a channel we have just joined.
    ///
    /// Against a bouncer this is the difference between reattaching into a conversation and
    /// reattaching into a blank window. `LATEST <target> * <limit>` is "the most recent
    /// messages, however far back that is" — the right question on a first join, where
    /// there is nothing in the buffer to be more specific than.
    ///
    /// **Our own join only.** Everyone else joining a channel is not an occasion to ask the
    /// server for its history again, and a busy channel would otherwise produce one request
    /// per arrival.
    private func requestHistoryIfOurJoin(_ message: IRCMessage) async {
        guard negotiated.isEnabled(.chatHistory), configuration.chatHistoryLimit > 0,
            let channel = message.parameters.first,
            let who = message.source?.nick,
            capabilities.caseMapping.equal(who, currentNick)
        else { return }
        await connection?.send(
            IRCMessage(
                verb: "CHATHISTORY",
                parameters: ["LATEST", channel, "*", String(configuration.chatHistoryLimit)]
            )
        )
    }

    /// Applies one `BOUNCER NETWORK`, whether from the `LISTNETWORKS` batch or from a
    /// later notification.
    ///
    /// Both spellings land here, and both emit the whole list rather than a delta —
    /// reconciling a list is much easier to get right in the consumer than applying a
    /// stream of edits, and the list is a dozen entries at most.
    private func handleBouncer(_ message: IRCMessage) {
        guard case .network(let id, let attributes)? = BouncerReply(message: message) else {
            return
        }
        guard let attributes else {
            bouncerNetworks.removeAll { $0.id == id }
            emit(.bouncerNetworks(bouncerNetworks))
            return
        }
        if let index = bouncerNetworks.firstIndex(where: { $0.id == id }) {
            // An update carries only what changed, so it is merged rather than replacing.
            bouncerNetworks[index].apply(attributes: attributes)
        } else {
            bouncerNetworks.append(BouncerNetwork(id: id, attributes: attributes))
        }
        emit(.bouncerNetworks(bouncerNetworks))
    }

    /// `PRIVMSG NickServ :IDENTIFY <account> <password>`, once, after registration.
    ///
    /// Redaction is not this function's business and deliberately so: `TraceBuffer` strips
    /// the arguments of a NickServ `IDENTIFY` on insert, which covers this line, the one a
    /// user types by hand, and any other route to the same command.
    private func identifyToNickServIfNeeded() async {
        guard let (account, password) = pendingIdentify else { return }
        pendingIdentify = nil
        emit(.clientNotice("identifying to NickServ as \(account)"))
        await connection?.send(
            IRCMessage(
                verb: "PRIVMSG",
                parameters: ["NickServ", "IDENTIFY \(account) \(password)"]
            )
        )
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
        emit(.stateChanged(newState))
    }

    private func setCurrentNick(_ nick: String) {
        currentNick = nick
        roster.setOwnNick(nick)
    }

    /// Broadcasts an event, then the snapshot of every channel it changed.
    ///
    /// The order matters and is the contract: a consumer sees the `JOIN` line before the
    /// nick list that now includes them, so a buffer renders its own event and *then*
    /// redraws. One `QUIT` can produce several snapshots — one per channel shared with
    /// the user — which is exactly what "reported per-channel" means.
    private func emit(_ event: IRCEvent) {
        multicaster.broadcast(event)
        for name in roster.apply(event) {
            guard let channel = roster[name] else { continue }
            multicaster.broadcast(.channelChanged(channel))
        }
    }
}
