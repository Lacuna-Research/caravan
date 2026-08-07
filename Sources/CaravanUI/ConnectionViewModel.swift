import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import IRCTransport
import Observation

/// One connection, as the UI sees it: a status window, a channel window per channel, a
/// lifecycle state, and a way to type at the server.
///
/// Owns the event pump. Every event becomes at most one line, in whichever buffer it
/// belongs to, and the pump runs on the main actor so appends need no hop of their own.
@MainActor
@Observable
public final class ConnectionViewModel: Identifiable {
    public let id = UUID()

    /// The status window's scrollback. The network row in the tree opens it.
    public let log = MessageLogController()

    public private(set) var state: SessionState = .disconnected(reason: .notStarted)
    public private(set) var currentNick: String

    /// What the tree calls this network.
    ///
    /// The host, until something better is known: a bouncer-bound connection takes the
    /// upstream network's own name, and `NETWORK=` from `ISUPPORT` improves on a bare
    /// hostname for a direct one. A user reading the tree wants "Libera.Chat", not
    /// "irc.libera.chat", and certainly not "soju.example.org" for both of two networks
    /// reached through the same bouncer.
    public private(set) var displayName: String

    /// Whether this network's channels are showing in the tree.
    ///
    /// Per connection, not per app: with two networks open, one flag collapses both. Moved
    /// off `AppModel` in prompt 4, which is what stage 1 prompt 8's note asked for.
    public var isExpanded = true

    /// The upstream networks this bouncer is holding, empty for everything else.
    ///
    /// Only ever non-empty on the *unbound* connection to a bouncer — the one allowed to
    /// enumerate. `AppModel` reconciles the tree against this.
    public private(set) var bouncerNetworks: [BouncerNetwork] = []

    /// The bouncer network this connection is bound to, or `nil` for a direct connection
    /// and for the bouncer's own control connection.
    public var bouncerNetworkID: String? { configuration.bouncerNetworkID }

    /// Called when ``bouncerNetworks`` changes, so the app can open and close the rows.
    ///
    /// A callback rather than the app observing the property: opening a network is an
    /// `async` operation on `AppModel`, and `@Observable` gives no hook to run one from.
    @ObservationIgnored
    public var bouncerNetworksDidChange: (@MainActor (ConnectionViewModel) -> Void)?

    /// Renames the row, for a bouncer network the bouncer has renamed under us.
    public func rename(to name: String) {
        guard !name.isEmpty, name != displayName else { return }
        displayName = name
    }

    /// Where this connection points, which is what makes two of them the same network.
    public let host: String
    public let port: UInt16

    /// Channel buffers in join order, which is the order the tree shows them in.
    public private(set) var channels: [ChannelBuffer] = []

    /// Query buffers, in the order the conversations started.
    ///
    /// A second array rather than a `kind` on one, because the tree sorts queries *after*
    /// channels (§12) and that rule is then the order two arrays are concatenated in
    /// rather than a comparator that has to be right everywhere it is written.
    public private(set) var queries: [QueryBuffer] = []

    /// The status window's input box and its history. Per buffer, like every other.
    public let statusInput = InputState()

    /// The server's message of the day, for the status window's header band.
    ///
    /// Accumulated across 372s and published when 376 ends the burst, so the band does not
    /// grow a line at a time while the MOTD streams in.
    public private(set) var motd: String?

    @ObservationIgnored private var motdLines: [String] = []

    /// Appearance, shared with every other buffer: one chat font, one timestamp format,
    /// one raw-traffic toggle.
    @ObservationIgnored public let settings: ChatSettings

    private var renderer: LineRenderer { settings.renderer }

    @ObservationIgnored private var buffersByName: [IRCChannelName: ChannelBuffer] = [:]
    @ObservationIgnored private var queriesByNick: [IRCNick: QueryBuffer] = [:]

    /// The casemapping the session is folding names under, learned from the events that
    /// carry one. Starts at the `ISUPPORT` default, as the session's own does.
    @ObservationIgnored private var caseMapping: IRCCaseMapping = .rfc1459

    /// What `CAP` negotiation settled on, mirrored from the session's own.
    ///
    /// Read on the send path, which is synchronous with respect to the user's keystroke —
    /// so it is kept here rather than `await`ed off the actor for every line typed.
    public private(set) var capabilities = NegotiatedCapabilities()

    @ObservationIgnored private let session: IRCSession
    @ObservationIgnored public let configuration: SessionConfiguration
    @ObservationIgnored private var pump: Task<Void, Never>?

    /// A name supplied by whoever created this connection, which outranks anything learned
    /// from the wire. The bouncer's own word for a network beats that network's `NETWORK=`.
    @ObservationIgnored private let givenName: String?

    public init(
        configuration: SessionConfiguration,
        trace: TraceBuffer,
        settings: ChatSettings = ChatSettings(),
        credentials: TLSCredentials = TLSCredentials(),
        name: String? = nil
    ) {
        self.session = IRCSession(
            configuration: configuration,
            trace: trace,
            credentials: credentials
        )
        self.configuration = configuration
        self.currentNick = configuration.nick
        self.host = configuration.host
        self.port = configuration.port
        self.givenName = name
        self.displayName = name ?? configuration.host
        self.settings = settings
        log.chatFont = ChatFont.nsFont(family: settings.fontFamily, size: settings.fontSize)
        log.palette = settings.palette
    }

    deinit {
        pump?.cancel()
    }

    /// A one-line summary for the tree row and the window's status area.
    public var statusSummary: String {
        switch state {
        case .disconnected(let reason):
            switch reason {
            case .notStarted: "Not connected"
            case .userInitiated: "Disconnected"
            default: LineRenderer.statusLine(for: state) ?? "Disconnected"
            }
        case .connecting: "Connecting…"
        case .registering: "Registering…"
        case .connected: "Connected as \(currentNick)"
        case .reconnecting(let attempt, _): "Reconnecting (attempt \(attempt))…"
        }
    }

    public var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    public func buffer(named name: IRCChannelName) -> ChannelBuffer? { buffersByName[name] }

    public func query(named nick: IRCNick) -> QueryBuffer? { queriesByNick[nick] }

    /// Opens a conversation window, or returns the one already open. `/query`'s action.
    ///
    /// The one public way to create a query buffer without a message arriving, which is
    /// what makes `/query bob` a complete command rather than a message with no text.
    ///
    /// **Asynchronous for the casemapping, which is not decoration.** Query buffers are
    /// keyed by nick, and the mirrored mapping is only refreshed by events that carry a
    /// folded name — so `/query bob` before any traffic would key the buffer under the
    /// `ISUPPORT` default while bob's reply arrives folded under the server's real one,
    /// and the same person would get two windows.
    @discardableResult
    public func openQuery(with nick: String) async -> QueryBuffer {
        caseMapping = await session.capabilities.caseMapping
        return query(creating: IRCNick(nick, mapping: caseMapping))
    }

    /// Closes a conversation window.
    ///
    /// **Nothing goes on the wire.** A query has no membership to leave — closing it is
    /// closing a window, which is exactly why ⌘W on one is not the same act as ⌘W on a
    /// channel, where it parts.
    public func closeQuery(_ nick: IRCNick) {
        guard queriesByNick.removeValue(forKey: nick) != nil else { return }
        queries.removeAll { $0.nick == nick }
    }

    // MARK: - Control

    public func connect() async {
        // Subscribing *before* connecting is load-bearing: the event stream does not
        // replay, so a subscriber that arrives afterwards silently misses the start of
        // the connection — which is exactly the part a user is watching for.
        startPumpIfNeeded()
        await session.connect()
    }

    public func disconnect() async {
        await session.disconnect()
    }

    /// Closes a channel buffer, which parts the channel.
    ///
    /// The invariant this half enforces: membership never outlives its buffer. The other
    /// half — that a buffer may outlive membership — is why `/part` and a kick leave the
    /// buffer in place, greyed.
    public func closeChannel(_ name: IRCChannelName) async {
        await session.closeChannel(name)
    }

    // MARK: - The command layer

    /// What a line of input asks for, parsed against the server's live capabilities.
    ///
    /// Read straight off the actor rather than cached: this is async anyway, so there is
    /// no window in which the parser's idea of `CHANTYPES` can be stale.
    public func actions(for text: String, activeTarget: Target?) async -> [CommandAction] {
        CommandParser(capabilities: await session.capabilities)
            .actions(for: text, activeTarget: activeTarget)
    }

    /// Sends a message, echoing what we said into the windows it belongs in.
    ///
    /// Two echoes, and they answer different questions.
    ///
    /// - **The window you typed in**, when the message was aimed somewhere else: `/msg
    ///   bob hi` typed in `#swift` shows `-> *bob* hi` there. mIRC's form, and the only
    ///   way to see that it sent without leaving the window. Drawn whether or not
    ///   `echo-message` is on, because the server's copy goes to bob's window and says
    ///   nothing about where you were standing when you sent it.
    /// - **The recipient's own window**: `<you> hi` in bob's query, or in `#swift`.
    ///   Drawn *only* without `echo-message` — with it, the server's copy is the better
    ///   one, since it carries the `server-time` the message was accepted at and its
    ///   message id, and arrives in the order everyone else sees it.
    ///
    /// This is the filter `LineKind.isSelfEcho` was built for: one condition on the way
    /// out, rather than trying to recognise our own words coming back.
    ///
    /// The wire form goes to the status window instead, and only when the raw-traffic
    /// toggle is on — that is where `>>` markers belong.
    public func send(_ message: IRCMessage, from target: Target?) async {
        // Read off the actor rather than mirrored: classifying the recipient needs
        // `CHANTYPES`, and this path is one keystroke rather than one line of scrollback.
        let serverCapabilities = await session.capabilities
        appendRaw(message.wireForm, kind: .rawOutbound)
        echo(message, from: target, capabilities: serverCapabilities)
        await session.send(message)
    }

    /// Shows a usage or argument error in the window it came from.
    ///
    /// The same red line an unparseable message already produced, reused rather than
    /// reinvented: input never disappears without an answer.
    public func showError(_ text: String, in target: Target?) {
        log(for: target).append([renderer.line(text, kind: .clientError)])
    }

    /// Shows something the client wants to say that is not an error — `/debug`'s answers.
    ///
    /// Deliberately not the red `.clientError` line: telling a user "the debug log is now
    /// at ~/caravan.log" in the colour reserved for failures teaches them to distrust the
    /// colour.
    public func showNotice(_ text: String, in target: Target?) {
        log(for: target).append([renderer.line(text, kind: .status)])
    }

    /// Adopts changed settings across every buffer this connection owns.
    ///
    /// The font and the line cap are held by each `MessageLogController` rather than read
    /// from the settings per line, so changing them in the form has to reach the existing
    /// buffers — otherwise the setting only applies to windows opened afterwards, which is
    /// the sort of half-working that is worse than not offering it.
    public func applySettings() {
        let font = ChatFont.nsFont(family: settings.fontFamily, size: settings.fontSize)
        let palette = settings.palette
        for controller in [log] + channels.map(\.log) + queries.map(\.log) {
            controller.chatFont = font
            controller.lineCap = settings.scrollbackLines
            controller.palette = palette
        }
    }

    /// Draws what we just sent, wherever it belongs. See ``send(_:from:)``.
    ///
    /// `PRIVMSG` and `NOTICE` only. A `JOIN` or a `MODE` produces no echo because the
    /// server will tell us about it in a moment, and echoing it here would show it twice.
    /// A CTCP *request* we sent produces none either: it is a question addressed to a
    /// client, not something said, and it arrives back as its own reply line. `ACTION` is
    /// the exception, being a message wearing a CTCP's wrapper.
    private func echo(
        _ message: IRCMessage,
        from target: Target?,
        capabilities serverCapabilities: ServerCapabilities
    ) {
        guard case .verb(let verb) = message.command, message.parameters.count >= 2 else {
            return
        }
        let isNotice: Bool
        switch verb.uppercased() {
        case "PRIVMSG": isNotice = false
        case "NOTICE": isNotice = true
        default: return
        }

        let body = message.parameters[1]
        if let ctcp = CTCPMessage(text: body), !ctcp.isAction { return }
        let (text, isAction) = EventTranslator.unwrapAction(body)
        let recipient = message.parameters[0]

        // **A message addressed somewhere other than this window is marked as such.** The
        // live acceptance run found `/msg bob hi` rendering in `#swift` as `<@you> hi`,
        // indistinguishable from something said in the channel — a client lying about
        // where your words went.
        if !isThisWindow(recipient, target) {
            var fields = LineFields()
            fields.text = text
            fields.nick = recipient
            log(for: target)
                .append([
                    renderer.line(
                        kind: isNotice ? .ownPrivateNotice : .ownPrivateMessage,
                        fields: fields
                    )
                ])
        }

        // The window is opened whether or not the server will echo for us; only the
        // *line* is conditional. Otherwise `/msg bob hi` would open a conversation on a
        // network without `echo-message` and, for as long as the round trip takes, not on
        // one with it — the capability leaking into behaviour by way of a race.
        let destination = Target(recipient, capabilities: serverCapabilities)
        guard let buffer = echoDestination(destination, isNotice: isNotice) else { return }
        guard !capabilities.isEnabled(.echoMessage) else { return }

        var fields = LineFields()
        fields.text = text
        fields.nick = ownDisplayName(in: destination)
        let kind: LineKind = isAction ? .ownAction : (isNotice ? .ownNotice : .ownMessage)
        buffer.append([renderer.line(kind: kind, fields: fields)])

        if case .nick(let nick) = destination {
            queriesByNick[nick]?
                .record(sender: currentNick, text: text, isAction: isAction, at: Date())
        }
    }

    /// The recipient's own window, opening a query for it where that is the right thing.
    ///
    /// **A `PRIVMSG` to a nick opens the window; a `NOTICE` does not.** The same rule the
    /// inbound side follows, and it has to be the same rule: under `echo-message` the
    /// server's copy of what we sent comes back through the inbound path, so a `/msg` that
    /// opened a window on one network and not on another would be the capability leaking
    /// into behaviour. `nil` means there is nowhere for it to go and nothing to draw.
    private func echoDestination(_ target: Target, isNotice: Bool) -> MessageLogController? {
        switch target {
        case .channel(let name):
            return buffersByName[name]?.log
        case .nick(let nick):
            if isNotice { return queriesByNick[nick]?.log }
            return query(creating: nick).log
        }
    }

    /// Whether a recipient names the window the message was typed in.
    ///
    /// Folded under the live casemapping rather than compared literally: `#Swift` and
    /// `#swift` are the window you are in, and rendering your own line as though it went
    /// elsewhere because of a capital letter would be its own small lie.
    private func isThisWindow(_ recipient: String, _ target: Target?) -> Bool {
        guard let target else { return false }
        return caseMapping.equal(recipient, target.raw)
    }

    /// Our own nick with whatever prefix we hold in this channel, as the nick column
    /// shows any other sender.
    private func ownDisplayName(in target: Target?) -> String {
        guard case .channel(let name)? = target, let buffer = buffersByName[name] else {
            return currentNick
        }
        let key = IRCNick(currentNick, mapping: name.mapping)
        guard let member = buffer.channel.members[key],
            let prefix = buffer.channel.prefix(for: member)
        else { return currentNick }
        return "\(prefix)\(currentNick)"
    }

    /// One line of wire traffic, when the toggle is on.
    ///
    /// Redacted on the way in, like everything else that leaves the socket: the raw view
    /// of a `PASS` or a NickServ `identify` must not be the one place the plaintext shows
    /// up. The status window is where both directions land, since wire traffic belongs to
    /// the connection rather than to any buffer.
    private func appendRaw(_ line: String, kind: LineKind) {
        guard settings.showsRawTraffic else { return }
        log.append([renderer.line(Redactor.redact(line), kind: kind)])
    }

    /// `/quit`: say goodbye, then drop the connection.
    ///
    /// The disconnect is not merely tidy. A server answers `QUIT` with `ERROR` and closes,
    /// which the session would otherwise read as a failure worth reconnecting from — going
    /// through `disconnect()` is what marks this one as ours.
    public func quit(reason: String?) async {
        await session.send(IRCMessage(verb: "QUIT", parameters: reason.map { [$0] } ?? []))
        await session.disconnect()
    }

    /// The scrollback a window's input writes into.
    private func log(for target: Target?) -> MessageLogController {
        switch target {
        case .channel(let name)?: buffersByName[name]?.log ?? log
        case .nick(let nick)?: queriesByNick[nick]?.log ?? log
        case nil: log
        }
    }

    // MARK: - Events

    private func startPumpIfNeeded() {
        guard pump == nil else { return }
        let events = session.events()
        pump = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: IRCEvent) {
        noteCaseMapping(in: event)
        switch event {
        case .stateChanged(let newState):
            state = newState
        case .registered(let info):
            currentNick = info.nick
        case .nickChanged(let who, let newNick):
            if who.nick.map({ isOwn(nick: $0) }) == true { currentNick = newNick }
        case .channelChanged(let channel):
            buffer(creating: channel.name).update(channel)
        case .channelClosed(let name):
            removeBuffer(name)
        case .numeric(let code, let parameters):
            collectMOTD(code: code, parameters: parameters)
            if code == 5 { adoptNetworkName(fromISUPPORT: parameters) }
        case .capabilitiesChanged(let negotiated):
            capabilities = negotiated
        case .bouncerNetworks(let networks):
            bouncerNetworks = networks
            bouncerNetworksDidChange?(self)
        default:
            break
        }
        append(event)
    }

    /// Takes the network's own name from `ISUPPORT`, when nobody supplied a better one.
    ///
    /// `NETWORK=Libera.Chat` is what the network calls itself, and it is a better tree row
    /// than `irc.libera.chat`. A name passed in at construction — the bouncer's word for an
    /// upstream network — outranks it, because the bouncer is the thing that knows there
    /// are several networks behind one host.
    private func adoptNetworkName(fromISUPPORT parameters: [String]) {
        guard givenName == nil else { return }
        for token in parameters where token.hasPrefix("NETWORK=") {
            let name = String(token.dropFirst("NETWORK=".count))
            if !name.isEmpty { displayName = name }
        }
    }

    private func append(_ event: IRCEvent) {
        // Every inbound line has somewhere to land, whether or not it was understood.
        if case .raw(let message) = event {
            appendRaw(message.wireForm, kind: .rawInbound)
            return
        }
        let context = RenderContext(
            ownNick: currentNick,
            senderPrefix: senderPrefix(for: event),
            now: serverTime(of: event) ?? Date()
        )
        guard let line = renderer.line(for: event, context: context) else { return }
        for destination in destinations(for: event) {
            destination.append([line])
        }
        noteConversation(event, at: context.now)
    }

    /// Records a private message in its query's header band (§14).
    ///
    /// After ``destinations(for:)``, which is what opened the buffer: a message that did
    /// not earn a window has no conversation to be part of.
    private func noteConversation(_ event: IRCEvent, at when: Date) {
        guard case .message(let target, let sender, let text, _, let isAction, _) = event,
            let who = sender.nick,
            let other = correspondent(target: target, sender: sender),
            let buffer = queriesByNick[other]
        else { return }
        buffer.record(sender: who, text: text, isAction: isAction, at: when)
    }

    /// The other party in a message addressed to a nick, or `nil` when there is not one.
    ///
    /// **Which end of it we are decides where to look.** An inbound message names us as
    /// the target and the conversation is with the *sender*; our own message coming back
    /// under `echo-message` — or replayed out of a bouncer's backlog — names us as the
    /// sender and the conversation is with the *target*. One window either way, which is
    /// the whole point.
    ///
    /// A message from a server rather than a person has no nick and gets no window: `:irc
    /// .libera.chat NOTICE alice :...` is the network talking, and it belongs in the
    /// status window with the rest of what the network says.
    private func correspondent(target: Target, sender: IRCSource) -> IRCNick? {
        guard case .nick(let targetNick) = target, let senderNick = sender.nick else {
            return nil
        }
        return isOwn(nick: senderNick)
            ? targetNick : IRCNick(senderNick, mapping: targetNick.mapping)
    }

    /// When a line was *said*, under `server-time`, or `nil` for one that has no such tag.
    ///
    /// This is what the capability is for: a line replayed out of a bouncer's backlog was
    /// said an hour ago, and stamping it with the moment it happened to arrive is a client
    /// telling the user something untrue. `RenderContext.now` is where it lands, so nothing
    /// below the renderer has to know the difference.
    ///
    /// Only messages carry their tags today. Prompt 4 replays joins and topics through
    /// `chathistory` and will want the same for those.
    private func serverTime(of event: IRCEvent) -> Date? {
        let tags: IRCTags
        switch event {
        case .message(_, _, _, _, _, let messageTags): tags = messageTags
        case .ctcpRequest(_, _, _, let ctcpTags), .ctcpReply(_, _, _, let ctcpTags):
            tags = ctcpTags
        default: return nil
        }
        guard let value = tags.value(for: "time") else { return nil }
        return Self.parseServerTime(value)
    }

    /// IRCv3's timestamp is `2011-10-19T16:40:51.620Z`, but the fractional part is
    /// optional in practice and several servers omit it — so both are accepted rather than
    /// silently falling back to the arrival time for half the networks.
    static func parseServerTime(_ value: String) -> Date? {
        withFractionalSeconds.date(from: value) ?? withoutFractionalSeconds.date(from: value)
    }

    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The prefix the sender of a channel message holds there, e.g. `@`.
    ///
    /// Only messages have a nick column, and a message has exactly one channel, so there
    /// is no ambiguity about which buffer to ask.
    private func senderPrefix(for event: IRCEvent) -> Character? {
        guard case .message(let target, let sender, _, _, _, _) = event,
            case .channel(let name) = target,
            let buffer = buffersByName[name],
            let nick = sender.nick
        else { return nil }
        let member = buffer.channel.members[IRCNick(nick, mapping: name.mapping)]
        return member.flatMap { buffer.channel.prefix(for: $0) }
    }

    /// Collects the MOTD for the status window's header band.
    ///
    /// 375 opens the burst, 372 carries each line, 376 closes it, and 422 says there is
    /// none. Published at the end rather than per line, so the band does not grow a line
    /// at a time while a long MOTD streams in.
    private func collectMOTD(code: UInt16, parameters: [String]) {
        switch code {
        case 375:
            motdLines = []
        case 372:
            if let text = parameters.last { motdLines.append(text) }
        case 376:
            motd = motdLines.isEmpty ? nil : motdLines.joined(separator: "\n")
            motdLines = []
        case 422:
            motd = parameters.last
        default:
            break
        }
    }

    /// Which buffers an event is shown in.
    ///
    /// Channel-scoped events go to their channel and nowhere else; a `QUIT` or a `NICK`
    /// goes to every channel that had the user, which is how mIRC has always reported
    /// them. Anything not about a channel we have a window for lands in the status
    /// window, so nothing is silently dropped.
    private func destinations(for event: IRCEvent) -> [MessageLogController] {
        switch event {
        case .joined(let channel, let who, _, _):
            // The only event that opens a window: the server tells us we joined, and mIRC
            // has opened the window on that line for thirty years.
            if who.nick.map({ isOwn(nick: $0) }) == true {
                return [buffer(creating: channel).log]
            }
            return [existing(channel)].compactMap(\.self)

        case .parted(let channel, _, _),
            .kicked(let channel, _, _, _),
            .topicChanged(let channel, _, _),
            .topicAuthor(let channel, _, _),
            .channelModes(let channel, _),
            .joinFailed(let channel, _, _):
            return [existing(channel) ?? log]

        case .modeChanged(let target, _, _):
            guard case .channel(let name) = target else { return [log] }
            return [existing(name) ?? log]

        case .message(let target, let sender, _, let kind, _, _):
            if case .channel(let name) = target { return [existing(name) ?? log] }
            guard let other = correspondent(target: target, sender: sender) else { return [log] }
            // **A notice never opens a window.** Services, the bouncer and half the
            // network send them, and a window per sender is how mIRC's status window came
            // to exist in the first place. One that is already open is still the right
            // place for it — NickServ answering in the NickServ query is what you want.
            if kind == .notice { return [queriesByNick[other]?.log ?? log] }
            return [query(creating: other).log]

        case .ctcpRequest(let target, let sender, _, _),
            .ctcpReply(let target, let sender, _, _):
            // Shown, never window-opening. A CTCP is a client talking to a client, and a
            // `VERSION` from a stranger — or from fifty of them — must not be able to
            // conjure fifty windows. It lands in the conversation if there is one, and in
            // the status window otherwise.
            if case .channel(let name) = target, let buffer = existing(name) { return [buffer] }
            guard let other = correspondent(target: target, sender: sender) else { return [log] }
            return [queriesByNick[other]?.log ?? log]

        case .quit(let who, _):
            return buffersContaining(nick: who.nick).map(\.log)

        case .nickChanged(let who, _):
            let shared = buffersContaining(nick: who.nick).map(\.log)
            // Our own rename is news everywhere, including where we share no channel.
            let isOwnRename = who.nick.map { isOwn(nick: $0) } == true
            return isOwnRename || shared.isEmpty ? [log] + shared : shared

        case .awayChanged(let who, _), .accountChanged(let who, _),
            .hostChanged(let who, _, _), .realNameChanged(let who, _):
            // These describe a person, not a channel, so they land wherever that person
            // is visible — the same rule a `QUIT` follows, and for the same reason.
            return buffersContaining(nick: who.nick).map(\.log)

        case .invited(_, _, let channel):
            // An invitation to a channel we already have a window for belongs there; one
            // to a channel we have never seen has nowhere else to go but the status
            // window, which is exactly where an offer to join something should appear.
            return [existing(channel) ?? log]

        case .stateChanged, .registered, .numeric, .clientError, .clientNotice, .raw,
            .namesReply, .endOfNames, .channelChanged, .channelClosed,
            .capabilitiesChanged, .authenticated, .standardReply,
            .batchStarted, .batchEnded, .bouncerNetworks:
            return [log]
        }
    }

    /// Buffers whose member list still contains `nick`.
    ///
    /// Still contains, because the snapshot that removes them arrives *after* the event
    /// being rendered — which is exactly what makes routing a `QUIT` possible at all.
    private func buffersContaining(nick: String?) -> [ChannelBuffer] {
        guard let nick else { return [] }
        return channels.filter { $0.channel.contains(IRCNick(nick, mapping: $0.name.mapping)) }
    }

    /// Comparing nicks with `lowercased()` would make `Foo[]` and `foo{}` different people
    /// on an rfc1459 server, so this uses whatever the session last folded a name under.
    private func isOwn(nick: String) -> Bool {
        caseMapping.equal(nick, currentNick)
    }

    /// Learns the server's casemapping from the events that carry a folded name.
    ///
    /// The session is the authority on it, and every channel name it hands out was folded
    /// under the live mapping — so there is no need for a second channel to publish it,
    /// and no window where the two disagree. Until the first such event the `ISUPPORT`
    /// default stands, which is what the session assumes too.
    private func noteCaseMapping(in event: IRCEvent) {
        switch event {
        case .joined(let channel, _, _, _), .parted(let channel, _, _),
            .kicked(let channel, _, _, _), .topicChanged(let channel, _, _),
            .topicAuthor(let channel, _, _), .channelModes(let channel, _),
            .namesReply(let channel, _), .endOfNames(let channel),
            .joinFailed(let channel, _, _), .channelClosed(let channel),
            .invited(_, _, let channel):
            caseMapping = channel.mapping
        case .channelChanged(let channel):
            caseMapping = channel.mapping
        case .message(let target, _, _, _, _, _), .modeChanged(let target, _, _),
            .ctcpRequest(let target, _, _, _), .ctcpReply(let target, _, _, _):
            // Every target was folded under the live mapping on its way here, channel or
            // nick — which is what makes a nick-keyed query dictionary safe.
            caseMapping = target.mapping
        case .raw, .stateChanged, .registered, .quit, .nickChanged, .numeric,
            .clientError, .clientNotice, .capabilitiesChanged, .authenticated,
            .standardReply, .awayChanged, .accountChanged, .hostChanged, .realNameChanged,
            .batchStarted, .batchEnded, .bouncerNetworks:
            break
        }
    }

    private func existing(_ name: IRCChannelName) -> MessageLogController? {
        buffersByName[name]?.log
    }

    private func buffer(creating name: IRCChannelName) -> ChannelBuffer {
        if let existing = buffersByName[name] { return existing }
        let buffer = ChannelBuffer(name: name)
        // One chat font and one palette govern every buffer; a new one adopts them rather
        // than defaulting.
        buffer.log.chatFont = ChatFont.nsFont(
            family: settings.fontFamily,
            size: settings.fontSize
        )
        buffer.log.palette = settings.palette
        buffersByName[name] = buffer
        channels.append(buffer)
        return buffer
    }

    private func query(creating nick: IRCNick) -> QueryBuffer {
        if let existing = queriesByNick[nick] { return existing }
        let buffer = QueryBuffer(nick: nick)
        buffer.log.chatFont = ChatFont.nsFont(
            family: settings.fontFamily,
            size: settings.fontSize
        )
        buffer.log.palette = settings.palette
        buffer.log.lineCap = settings.scrollbackLines
        queriesByNick[nick] = buffer
        queries.append(buffer)
        return buffer
    }

    private func removeBuffer(_ name: IRCChannelName) {
        guard buffersByName.removeValue(forKey: name) != nil else { return }
        channels.removeAll { $0.name == name }
    }
}
