import AppKit
import Diagnostics
import Foundation
import IRCFormat
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

    /// The status window, which is a buffer like any other. The network row opens it.
    ///
    /// An object rather than a loose scrollback since prompt 6: the flat list every
    /// navigation feature walks wants a uniform element, and a status window that was the
    /// one exception meant a special case in four places rather than one indirection here.
    public let status: StatusBuffer

    /// The status window's scrollback, for the many callers that only ever wanted that.
    public var log: MessageLogController { status.log }

    public private(set) var state: SessionState = .disconnected(reason: .notStarted)
    public private(set) var currentNick: String

    /// What the tree calls this network.
    ///
    /// The host, until something better is known: a bouncer-bound connection takes the
    /// upstream network's own name, and `NETWORK=` from `ISUPPORT` improves on a bare
    /// hostname for a direct one. A user reading the tree wants "Libera.Chat", not
    /// "irc.libera.chat", and certainly not "soju.example.org" for both of two networks
    /// reached through the same bouncer.
    public var displayName: String {
        get { status.displayName }
        set { status.displayName = newValue }
    }

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
    public var statusInput: InputState { status.input }

    /// The server's message of the day, for the status window's header band.
    ///
    /// Accumulated across 372s and published when 376 ends the burst, so the band does not
    /// grow a line at a time while the MOTD streams in.
    public private(set) var motd: String?

    @ObservationIgnored private var motdLines: [String] = []

    /// Appearance, shared with every other buffer: one chat font, one timestamp format,
    /// one raw-traffic toggle.
    @ObservationIgnored public let settings: ChatSettings

    /// Where the user has dragged this network's buffers, so a rejoin lands back there
    /// rather than at the bottom of a list they spent time arranging. `nil` in tests that
    /// do not care, where everything simply keeps join order.
    @ObservationIgnored public var bufferOrder: BufferOrder?

    /// Where the URLs in arriving lines are collected. Injected by `AppModel`, like
    /// ``bufferOrder``, and `nil` in the tests that do not care.
    @ObservationIgnored public var urlCatcher: URLCatcher?

    /// Where the conversation is written down, and read back from when a window opens.
    ///
    /// Injected like ``urlCatcher``, and `nil` in the tests that do not care — which is
    /// what makes "logging is off" and "there is no log" the same code path rather than two.
    @ObservationIgnored public var chatLog: ChatLog?

    /// Who is not to be shown. Injected like ``urlCatcher``, and `nil` in the tests that do
    /// not care — which makes "nothing is ignored" and "there is no list" one code path.
    @ObservationIgnored public var ignores: IgnoreList?

    /// What counts as somebody talking to you. `nil` falls back to your own nick alone,
    /// which is what every buffer did before there were rules to configure.
    @ObservationIgnored public var highlights: HighlightRules?

    /// Where an interruption goes once something has decided it is worth one. Injected like
    /// the rest, and `nil` in tests that only care about the activity state.
    @ObservationIgnored public var alerts: Alerts?

    /// Who is talking faster than a person talks. Per connection, because rates are.
    @ObservationIgnored private var floodDetector = FloodDetector()

    /// What this network last answered `LIST` with.
    ///
    /// Owned rather than injected, unlike its neighbours above: a channel list belongs to
    /// the connection that fetched it and has no meaning without one, and it survives a
    /// disconnect deliberately — it is data the user asked for, and reading it while
    /// reconnecting is reasonable.
    @ObservationIgnored public let channelDirectory = ChannelDirectory()

    /// Whether the *server* has us marked away. Set from 305 and 306 rather than assumed
    /// when `/away` is sent: the request can be ignored, and a client that believed itself
    /// would show the wrong thing on the servers that do.
    public private(set) var isAway = false

    /// Whether a buffer is on screen *and* the app is frontmost, which is the difference
    /// between a notification and noise. Supplied by `AppModel`, which is the only thing
    /// that knows either.
    @ObservationIgnored
    public var isBufferOnScreen: @MainActor (any ChatBuffer) -> Bool = { _ in false }

    /// Called when somebody on the notify list arrives or leaves, so the app can alert.
    /// A callback rather than the app reading the event stream, which the pump owns.
    @ObservationIgnored public var presenceDidChange: (@MainActor (String, Bool) -> Void)?

    /// Hands the session the list to watch. Called on connect and whenever the list changes.
    public func updateNotifyList(_ nicks: [String]) async {
        await session.setNotifyList(nicks)
    }

    /// `/away <reason>`, or `/away` to come back. Goes on the wire; ``isAway`` follows the
    /// server's answer rather than this call.
    public func setAway(_ reason: String?) async {
        await session.send(
            IRCMessage(verb: "AWAY", parameters: reason.map { [$0] } ?? [])
        )
    }

    /// Called after a buffer's activity state rises, so the Dock badge can be recomputed.
    /// A callback rather than the app observing, for the same reason
    /// ``bouncerNetworksDidChange`` is one.
    @ObservationIgnored public var activityDidChange: (@MainActor () -> Void)?

    private var renderer: LineRenderer { settings.renderer }

    @ObservationIgnored private var buffersByName: [IRCChannelName: ChannelBuffer] = [:]
    @ObservationIgnored private var queriesByNick: [IRCNick: QueryBuffer] = [:]

    /// The casemapping the session is folding names under, learned from the events that
    /// carry one. Starts at the `ISUPPORT` default, as the session's own does.
    @ObservationIgnored private var caseMapping: IRCCaseMapping = .rfc1459

    /// What the server said it supports, mirrored from the session's own.
    ///
    /// A synchronous copy for the views: the modes sheet needs `EXCEPTS`, `INVEX` and
    /// `CHANMODES` while drawing, and `body` cannot `await`. Refreshed when an `ISUPPORT`
    /// line arrives, which is the only thing that changes it.
    public private(set) var lastKnownCapabilities = ServerCapabilities()

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

    /// The server-list entry this connection came from — its ``NetworkName``.
    ///
    /// **The stable identifier**, and the one thing here the server cannot change: it is
    /// the user's, it survives a restart, and `binding.N`, `order.<name>.*` and stage 3's
    /// `libera/#swift` all key on it. Distinct from ``displayName``, which is what the
    /// *server* calls itself and is only ever shown.
    ///
    /// Empty for a connection made without an entry, which after this prompt means only a
    /// test that did not bother.
    @ObservationIgnored public var networkName: String = ""

    /// What the tree, the window title and the quick switcher call this network.
    ///
    /// **The user's name wins over the server's.** `displayName` is `ISUPPORT NETWORK=`,
    /// which is prettier — "Libera.Chat" against "libera" — and which two entries for the
    /// same network share exactly. Somebody keeping two Libera accounts would see two rows
    /// both called Libera.Chat and no way to tell which was which, and the name they chose
    /// is the one their bindings and scripts already use. `displayName` stays as the
    /// server's own word, for the prose that wants it.
    public var treeName: String {
        networkName.isEmpty ? displayName : networkName
    }

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
        self.status = StatusBuffer(displayName: name ?? configuration.host)
        self.settings = settings
        log.chatFont = settings.chatNSFont
        log.density = settings.density
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

    /// Every buffer this network owns, **in the order the tree shows them**: the status
    /// window, then channels in join order, then conversations (§12).
    ///
    /// The one place that order is written. Next-unread walks it, the quick-switcher lists
    /// it, and `SidebarTree` draws it — three readers that must not disagree about where
    /// `#swift` sits relative to `bob`.
    public var buffers: [(item: AppModel.SidebarItem, buffer: any ChatBuffer)] {
        [(.status(id), status)]
            + channels.map { (.channel(connection: id, channel: $0.name), $0 as any ChatBuffer) }
            + queries.map { (.query(connection: id, nick: $0.nick), $0 as any ChatBuffer) }
    }

    public func buffer(named name: IRCChannelName) -> ChannelBuffer? { buffersByName[name] }

    /// The highest activity state among this network's buffers.
    ///
    /// What a **collapsed** group shows (§9): a collapse that hides activity from you
    /// defeats the point of collapsing. The status window is included — it is one of the
    /// hidden children when the group is shut.
    public var rolledUpActivity: BufferActivity {
        buffers.map(\.buffer.activity).max() ?? .none
    }

    /// Moves channels within this network, and reports the new order for persisting.
    ///
    /// **Mutates `channels`, which is what ``buffers`` is built from** — so the tree,
    /// `AppModel.allBuffers`, next-unread and the ⌘K palette all move together. Reordering
    /// the *view* instead would have left the keyboard and the mouse disagreeing about
    /// where `#swift` is, which is exactly what prompt 6's carry-forward warned about.
    @discardableResult
    func moveChannels(fromOffsets source: IndexSet, toOffset destination: Int) -> [String] {
        channels.move(fromOffsets: source, toOffset: destination)
        return channels.map(\.name.raw)
    }

    @discardableResult
    func moveQueries(fromOffsets source: IndexSet, toOffset destination: Int) -> [String] {
        queries.move(fromOffsets: source, toOffset: destination)
        return queries.map(\.nick.raw)
    }

    /// Opens a channel's buffer without joining it, for a ⌘1–9 binding whose target is not
    /// open (§11).
    ///
    /// The buffer appears in its greyed not-joined state, which is the same appearance a
    /// parted channel and a disconnected network already wear (§16, §17) — so "reveal it
    /// in a disconnected state" needed no new appearance, only a way to make the buffer.
    @discardableResult
    public func openChannelBuffer(named name: IRCChannelName) -> ChannelBuffer {
        buffer(creating: name)
    }

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
        let key = IRCNick(nick, mapping: caseMapping)
        let isNew = queriesByNick[key] == nil
        let buffer = query(creating: key)
        // **Only for a window that did not exist a moment ago.** `/query bob` on a
        // conversation already open is a way to bring it to the front, and asking the
        // bouncer for its backlog again on every one of those would be a request per
        // keystroke's worth of impatience.
        if isNew { await session.requestHistory(for: nick) }
        return buffer
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
    /// What the server said it supports, read off the actor.
    ///
    /// Needed wherever a bare name has to be classified as a channel or a nick without a
    /// `Target` already in hand — resolving a ⌘1–9 binding, for one.
    public var serverCapabilities: ServerCapabilities {
        get async { await session.capabilities }
    }

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

    /// `/ban`, `/unban` and `/kickban`, with the mask worked out here.
    ///
    /// **This is why the parser hands over a person rather than a mask.** A useful ban is
    /// `*!*@host` — banning `bob!*@*` is defeated by typing `/nick bob2`, which is not
    /// much of a ban. The host lives in the channel roster, the roster lives here, and a
    /// pure parser has neither.
    ///
    /// A subject that already looks like a mask is passed through untouched, so
    /// `/ban *!*@evil.example` does exactly what it says.
    public func ban(
        channel: String,
        subject: String,
        isSet: Bool,
        kickReason: String?,
        from target: Target?
    ) async {
        let name = IRCChannelName(channel, mapping: caseMapping)
        let mask = banMask(for: subject, in: name)
        await send(
            IRCMessage(verb: "MODE", parameters: [channel, isSet ? "+b" : "-b", mask]),
            from: target
        )
        // **The ban goes out first.** Kicking before banning leaves a window, however
        // small, in which they can rejoin — and the whole point of `/kickban` over two
        // commands is that it closes it.
        guard let kickReason else { return }
        let parameters =
            kickReason.isEmpty ? [channel, subject] : [channel, subject, kickReason]
        await send(IRCMessage(verb: "KICK", parameters: parameters), from: target)
    }

    /// The mask to ban, from a nick or a mask.
    ///
    /// Falls back to `nick!*@*` when the host is not known — which happens for someone who
    /// has already left, or in a channel whose `NAMES` did not carry hosts. A weaker ban
    /// than intended is better than no ban and an error message.
    func banMask(for subject: String, in channel: IRCChannelName) -> String {
        // Anything with mask punctuation in it was written as a mask.
        guard !subject.contains("!"), !subject.contains("@"), !subject.contains("*") else {
            return subject
        }
        let key = IRCNick(subject, mapping: channel.mapping)
        guard let member = buffersByName[channel]?.channel.members[key],
            let host = member.host, !host.isEmpty
        else {
            return "\(subject)!*@*"
        }
        return "*!*@\(host)"
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
        let font = settings.chatNSFont
        let palette = settings.palette
        let density = settings.density
        for controller in [log] + channels.map(\.log) + queries.map(\.log) {
            controller.chatFont = font
            controller.density = density
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
        let now = Date()
        if !isThisWindow(recipient, target) {
            var fields = LineFields()
            fields.text = text
            fields.nick = recipient
            let kind: LineKind = isNotice ? .ownPrivateNotice : .ownPrivateMessage
            let origin = chatBuffer(for: target)
            origin.log.append([renderer.line(kind: kind, fields: fields, now: now)])
            record(kind: kind, fields: fields, in: origin, at: now)
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
        buffer.log.append([renderer.line(kind: kind, fields: fields, now: now)])
        record(kind: kind, fields: fields, in: buffer, at: now)

        // **Our clock stamped this line; the server will stamp its replay of it.** The two
        // agree to within a fraction of a second and disagree about which second that is
        // roughly half the time, so the neighbours are remembered as well. Two extra keys,
        // and without them a reattach to a server that has `chathistory` but not
        // `echo-message` shows you your own last few messages a second time.
        for offset in [-1.0, 0.0, 1.0] {
            buffer.replay.remember(
                ReplayKey(
                    date: now.addingTimeInterval(offset),
                    nick: fields.nick,
                    text: IRCFormatting.stripping(text)
                )
            )
        }

        if case .nick(let nick) = destination {
            queriesByNick[nick]?
                .record(sender: currentNick, text: text, isAction: isAction, at: now)
        }
    }

    /// Writes one line of our own to the log, when that buffer is logged.
    ///
    /// The echo path's counterpart to the one in ``append(_:)``. It exists separately
    /// because a locally echoed message has no event to render from — the server has not
    /// told us about it and, without `echo-message`, never will.
    private func record(
        kind: LineKind,
        fields: LineFields,
        in buffer: any ChatBuffer,
        at date: Date
    ) {
        guard let chatLog, settings.logs(buffer) else { return }
        chatLog.write(
            LineRenderer.plainLine(kind: kind, fields: fields, at: date),
            network: networkKey,
            buffer: buffer.displayName
        )
    }

    /// The recipient's own window, opening a query for it where that is the right thing.
    ///
    /// **A `PRIVMSG` to a nick opens the window; a `NOTICE` does not.** The same rule the
    /// inbound side follows, and it has to be the same rule: under `echo-message` the
    /// server's copy of what we sent comes back through the inbound path, so a `/msg` that
    /// opened a window on one network and not on another would be the capability leaking
    /// into behaviour. `nil` means there is nowhere for it to go and nothing to draw.
    private func echoDestination(_ target: Target, isNotice: Bool) -> (any ChatBuffer)? {
        switch target {
        case .channel(let name):
            return buffersByName[name]
        case .nick(let nick):
            if isNotice { return queriesByNick[nick] }
            return query(creating: nick)
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
    /// The scrollback a target names, falling back to the status window.
    ///
    /// Public since prompt 9: `/clear` used to reach for whatever the *tree* had selected,
    /// which is the wrong buffer when the line was typed in a detached window.
    public func log(for target: Target?) -> MessageLogController {
        chatBuffer(for: target).log
    }

    /// The buffer a target names, falling back to the status window.
    ///
    /// The same resolution ``log(for:)`` does, one level up — a caller that needs to know
    /// *which buffer* rather than merely where to append needs the object: whether it is
    /// logged, and what its de-duplication index holds.
    public func chatBuffer(for target: Target?) -> any ChatBuffer {
        switch target {
        case .channel(let name)?: buffersByName[name] ?? status
        case .nick(let nick)?: queriesByNick[nick] ?? status
        case nil: status
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
        // **Above everything else, and it is the twenty-two thousand that puts it here.**
        // Everything below — the case mapping, the ignore test, the render context with its
        // `Date()` — is per-event work that a `LIST` reply would multiply by the size of the
        // network, to produce a line that `LineRenderer` then declines to draw.
        switch event {
        case .channelListEntry(let channel, let members, let topic):
            channelDirectory.add(
                ChannelListing(name: channel, members: members, topic: topic)
            )
            return
        case .channelListEnd:
            channelDirectory.endCollecting()
            return
        default:
            break
        }

        noteCaseMapping(in: event)
        collectListMode(event)
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
            if code == 5 {
                adoptNetworkName(fromISUPPORT: parameters)
                // Read back off the actor rather than parsed again here: the session has
                // already applied this line, and a second parser would be a second answer.
                Task { [weak self] in
                    guard let self else { return }
                    self.lastKnownCapabilities = await self.session.capabilities
                }
            }
        case .capabilitiesChanged(let negotiated):
            capabilities = negotiated
        case .bouncerNetworks(let networks):
            bouncerNetworks = networks
            bouncerNetworksDidChange?(self)
        case .awayStateChanged(let away):
            isAway = away
        case .presenceChanged(let nick, let isOnline):
            presenceDidChange?(nick, isOnline)
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
        //
        // **Before the ignore test, deliberately.** The raw view is a diagnostic, and
        // somebody working out why they cannot see a person has to be able to see them.
        // An ignore is a display filter, never a censor of `/debug`.
        if case .raw(let message) = event {
            appendRaw(message.wireForm, kind: .rawInbound)
            return
        }

        // **One `return`, above all five consumers.** The line, the activity state, the URL
        // catcher, the chat log and the query's header band — the alternative is five
        // conditions and a sixth consumer that gets missed. Prompt 12's de-duplication sits
        // just below for the same reason, and this has to be above it: a line you were never
        // going to be shown should not consume a replay key either.
        //
        // Only the *rendering* is suppressed. `.channelChanged` is not an ignorable event,
        // so an ignored person still joins, still holds their op and still leaves the nick
        // list when they quit.
        guard let event = withIgnoresApplied(event) else { return }

        let context = RenderContext(
            ownNick: currentNick,
            senderPrefix: senderPrefix(for: event),
            now: serverTime(of: event) ?? Date()
        )

        // **Below the ignore filter, deliberately**, so somebody already ignored does not
        // keep feeding the counter and re-trip it every minute for as long as they flood.
        // Above the renderer, because a flood is a flood whether or not the line draws.
        noteForFlood(event, at: context.now)

        guard let line = renderer.line(for: event, context: context) else { return }

        // Built once for the whole event rather than per destination: the key is a property
        // of what was said, and the log line is expensive enough to be worth not repeating.
        let key = Self.replayKey(for: event, at: context.now)
        let logged = chatLog == nil ? nil : renderer.plainLine(for: event, context: context)

        var shown = false
        for destination in destinations(for: event) {
            // **The suppression is total, and that is the point.** A line the user has
            // already read must not raise the activity state, must not put its links in the
            // catcher and must not be written to the log a second time — a buffer that goes
            // pink for a line already on screen is worse than no de-duplication at all.
            if let key, destination.replay.consume(key) { continue }
            shown = true
            destination.log.append([line])
            // Read back off the line rather than scanned for again: the renderer's
            // `NSDataDetector` pass already decided what a URL is, and a second opinion
            // would eventually disagree with the underline the user can see.
            urlCatcher?.record(
                line,
                network: displayName,
                buffer: destination.displayName,
                date: context.now
            )
            let state = BufferActivity.caused(
                by: event,
                ownNick: currentNick,
                isConversation: destination.isConversation,
                highlights: highlights
            )
            raise(destination, to: state)
            alert(for: event, in: destination, state: state, at: context.now)
            if let key { destination.replay.remember(key) }
            if let logged, settings.logs(destination) {
                chatLog?.write(logged, network: networkKey, buffer: destination.displayName)
            }
        }
        guard shown else { return }
        noteConversation(event, at: context.now)
    }

    /// Counts a message towards its sender's rate, and ignores them if they are flooding.
    ///
    /// Only ``IRCEvent/message(target:sender:text:kind:tags:isAction:)`` — a flood is
    /// somebody *talking* at you. A netsplit's hundred `QUIT`s, a large `NAMES` and a
    /// `/list` reply are not floods and are not counted; the client that ignores a hundred
    /// people during a netsplit has made the situation considerably worse.
    private func noteForFlood(_ event: IRCEvent, at when: Date) {
        guard settings.autoIgnoresFloods, let ignores else { return }
        guard case .message(_, let sender, _, _, _, _) = event else { return }
        guard let nick = sender.nick, !isOwn(nick: nick) else { return }

        let folded = IRCNick(nick, mapping: caseMapping)
        guard floodDetector.record(nick: folded, at: when) else { return }

        // A mask on the nick alone, not `nick!user@host`: somebody flooding you and then
        // cycling their host is the ordinary case, and an ignore that a reconnect defeats is
        // not an ignore. It lapses on its own, so the cost of being broad is a minute.
        let entry = IgnoreEntry(
            mask: "\(nick)!*@*",
            levels: .all,
            expires: Date().addingTimeInterval(floodDetector.duration)
        )
        ignores.add(entry)
        showNotice(
            "\(nick) is flooding — ignored for "
                + "\(Int(floodDetector.duration)) seconds. See Options ▸ Ignore to undo it.",
            in: nil
        )
    }

    /// Interrupts the user, if this line is worth interrupting them for.
    ///
    /// **Strictly below the ignore filter**, which returned long ago for anything
    /// suppressed — that ordering is the whole reason prompt 13a shipped first, and it costs
    /// nothing as long as nothing moves above it. Also below the de-duplication `continue`,
    /// so a replayed line already on screen cannot alert twice.
    ///
    /// The decision itself is `Alerts.shouldAlert`, which takes everything it needs rather
    /// than reaching for `NSApp`; this only gathers the arguments.
    private func alert(
        for event: IRCEvent,
        in destination: any ChatBuffer,
        state: BufferActivity,
        at when: Date
    ) {
        guard let alerts, case .message(_, let sender, let text, _, _, _) = event else { return }
        // Named `isOurs` rather than `isOwn`: a local called `isOwn` shadows the method of
        // that name inside its own initialiser, which the compiler reports as "cannot call
        // value of non-function type Bool" three lines away from the cause.
        let isOurs = sender.nick.map { isOwn(nick: $0) } ?? false
        guard
            alerts.shouldAlert(
                activity: state,
                isConversation: destination.isConversation,
                isOwnMessage: isOurs,
                isOnScreen: isBufferOnScreen(destination),
                appIsActive: NSApplication.shared.isActive,
                at: when
            )
        else { return }
        alerts.post(
            Alert(
                source: "\(destination.displayName) on \(treeName)",
                sender: sender.nick,
                text: IRCFormatting.stripping(text),
                item: item(for: destination)
            )
        )
    }

    /// The sidebar row a buffer is, so a clicked notification can go there.
    private func item(for buffer: any ChatBuffer) -> AppModel.SidebarItem? {
        buffers.first { $0.buffer === buffer }?.item
    }

    /// The event as the ignore list leaves it: unchanged, stripped of its formatting, or
    /// `nil` for one that is not to be shown at all.
    ///
    /// **Two outcomes rather than one boolean**, because `k` is not a suppression. Six of
    /// the seven levels hide a line; `controlCodes` keeps it and takes the colours off,
    /// which is what you want for somebody whose every word is a different shade but who is
    /// still worth reading.
    private func withIgnoresApplied(_ event: IRCEvent) -> IRCEvent? {
        guard let ignores, let sender = Self.ignorableSender(of: event) else { return event }
        // **Never yourself.** A mask broad enough to catch your own `nick!user@host` — and
        // `*!*@*` is — would silently eat your own echo, which is a client appearing to
        // drop what you type.
        if let nick = sender.nick, isOwn(nick: nick) { return event }

        let level = ignores.levels(for: sender, mapping: caseMapping)
        guard !level.isEmpty else { return event }
        if let hiding = Self.ignoreLevel(hiding: event), level.contains(hiding) { return nil }
        guard level.contains(.controlCodes) else { return event }
        return Self.strippingCodes(event)
    }

    /// Whose event this is, for matching, or `nil` for one that has no person behind it.
    ///
    /// A `.server` source is deliberately excluded by ``IgnoreList/levels(for:mapping:)``
    /// rather than here, so the rule lives with the matcher; this only decides which events
    /// carry a sender at all.
    static func ignorableSender(of event: IRCEvent) -> IRCSource? {
        switch event {
        case .message(_, let sender, _, _, _, _),
            .ctcpRequest(_, let sender, _, _),
            .ctcpReply(_, let sender, _, _),
            .joined(_, let sender, _, _),
            .parted(_, let sender, _),
            .quit(let sender, _),
            .nickChanged(let sender, _):
            return sender
        case .invited(let by, _, _):
            return by
        default:
            return nil
        }
    }

    /// The level that would hide this event, or `nil` for one no level hides.
    ///
    /// A kick is deliberately absent: being thrown out of a channel is news about *you*,
    /// and a client that hid it because you had ignored the operator would leave you
    /// wondering why the window went quiet. Topic changes are absent for the same reason —
    /// the topic is the channel's, not the person's.
    static func ignoreLevel(hiding event: IRCEvent) -> IgnoreLevel? {
        switch event {
        case .message(let target, _, _, let kind, _, _):
            if kind == .notice { return .notices }
            if case .channel = target { return .channelMessages }
            return .privateMessages
        case .ctcpRequest, .ctcpReply:
            return .ctcps
        case .invited:
            return .invites
        case .joined, .parted, .quit, .nickChanged:
            return .movement
        default:
            return nil
        }
    }

    /// The same event with the formatting taken out of what was said — the `k` level.
    ///
    /// Only the cases that carry text somebody typed. Rewriting the event rather than
    /// telling the renderer about the ignore keeps the renderer a pure function of its
    /// input, which is what makes a rendered line testable without an ignore list.
    static func strippingCodes(_ event: IRCEvent) -> IRCEvent {
        guard
            case .message(let target, let sender, let text, let kind, let isAction, let tags) =
                event
        else { return event }
        return .message(
            target: target,
            sender: sender,
            text: IRCFormatting.stripping(text),
            kind: kind,
            isAction: isAction,
            tags: tags
        )
    }

    /// What makes an arriving message the same message as one already held, or `nil` for an
    /// event that a `chathistory` replay cannot produce.
    ///
    /// **Messages, actions and notices, and nothing else.** `chathistory` is message
    /// history: a bouncer does not replay joins, parts or topic changes, so a logged join
    /// has nothing to collide with and keying one would be machinery built for traffic that
    /// never arrives. This is the measurement the prompt 4 note asked for, and the answer it
    /// gives is that neither an event envelope nor `tags` on the replayed cases is needed.
    static func replayKey(for event: IRCEvent, at date: Date) -> ReplayKey? {
        guard case .message(_, let sender, let text, _, _, let tags) = event,
            let nick = sender.nick
        else { return nil }
        return ReplayKey(
            msgid: tags.value(for: "msgid"),
            date: date,
            nick: nick,
            // The key is compared against a line read back out of the log, where the codes
            // were stripped on the way in — so it has to be stripped here too, or a bold
            // word would make the same sentence two different lines.
            text: IRCFormatting.stripping(text)
        )
    }

    /// Collects a channel's ban / quiet / invite / except list as it arrives.
    ///
    /// Kept on the buffer rather than rebuilt from the scrollback: the lines are also
    /// *shown*, because someone who typed `/mode #swift +b` wants to read the answer where
    /// they asked — but a dialog that had to parse its own scrollback back into data would
    /// be absurd.
    private func collectListMode(_ event: IRCEvent) {
        switch event {
        case .listModeEntry(let channel, let mode, let mask, let setBy, let setAt):
            buffersByName[channel]?
                .recordListMode(mode, entry: ListModeEntry(mask: mask, setBy: setBy, setAt: setAt))
        case .listModeEnd(let channel, let mode):
            buffersByName[channel]?.finishListMode(mode)
        default:
            break
        }
    }

    /// Moves a buffer up to `state`, never down: a buffer holds the most urgent thing that
    /// has happened since you last looked at it, so a join arriving after a highlight does
    /// not quietly downgrade it.
    ///
    /// **The buffer you are looking at never accumulates one.** `AppModel` clears the
    /// selected buffer's state as it arrives, which is what makes the state mean "since you
    /// last looked" rather than "ever".
    private func raise(_ buffer: any ChatBuffer, to state: BufferActivity) {
        guard state > buffer.activity, !isSelected(buffer) else { return }
        buffer.activity = state
        activityDidChange?()
    }

    /// Whether a buffer is the one on screen. Set by `AppModel`, because the selection is
    /// the app's and a connection cannot see it.
    @ObservationIgnored
    public var isSelected: @MainActor (any ChatBuffer) -> Bool = { _ in false }

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
    private func destinations(for event: IRCEvent) -> [any ChatBuffer] {
        switch event {
        case .joined(let channel, let who, _, _):
            // The only event that opens a window: the server tells us we joined, and mIRC
            // has opened the window on that line for thirty years.
            if who.nick.map({ isOwn(nick: $0) }) == true {
                return [buffer(creating: channel)]
            }
            return [existing(channel)].compactMap(\.self)

        case .parted(let channel, _, _),
            .kicked(let channel, _, _, _),
            .topicChanged(let channel, _, _),
            .topicAuthor(let channel, _, _),
            .channelModes(let channel, _),
            .joinFailed(let channel, _, _),
            .listModeEntry(let channel, _, _, _, _),
            .listModeEnd(let channel, _):
            return [existing(channel) ?? status]

        case .modeChanged(let target, _, _):
            guard case .channel(let name) = target else { return [status] }
            return [existing(name) ?? status]

        case .message(let target, let sender, _, let kind, _, _):
            if case .channel(let name) = target { return [existing(name) ?? status] }
            guard let other = correspondent(target: target, sender: sender) else { return [status] }
            // **A notice never opens a window.** Services, the bouncer and half the
            // network send them, and a window per sender is how mIRC's status window came
            // to exist in the first place. One that is already open is still the right
            // place for it — NickServ answering in the NickServ query is what you want.
            if kind == .notice { return [queriesByNick[other] ?? status] }
            return [query(creating: other)]

        case .ctcpRequest(let target, let sender, _, _),
            .ctcpReply(let target, let sender, _, _):
            // Shown, never window-opening. A CTCP is a client talking to a client, and a
            // `VERSION` from a stranger — or from fifty of them — must not be able to
            // conjure fifty windows. It lands in the conversation if there is one, and in
            // the status window otherwise.
            if case .channel(let name) = target, let buffer = existing(name) { return [buffer] }
            guard let other = correspondent(target: target, sender: sender) else { return [status] }
            return [queriesByNick[other] ?? status]

        case .quit(let who, _):
            return buffersContaining(nick: who.nick)

        case .nickChanged(let who, _):
            let shared: [any ChatBuffer] = buffersContaining(nick: who.nick)
            // Our own rename is news everywhere, including where we share no channel.
            let isOwnRename = who.nick.map { isOwn(nick: $0) } == true
            return isOwnRename || shared.isEmpty ? [status] + shared : shared

        case .awayChanged(let who, _), .accountChanged(let who, _),
            .hostChanged(let who, _, _), .realNameChanged(let who, _):
            // These describe a person, not a channel, so they land wherever that person
            // is visible — the same rule a `QUIT` follows, and for the same reason.
            return buffersContaining(nick: who.nick)

        case .invited(_, _, let channel):
            // An invitation to a channel we already have a window for belongs there; one
            // to a channel we have never seen has nowhere else to go but the status
            // window, which is exactly where an offer to join something should appear.
            return [existing(channel) ?? status]

        case .channelListEntry, .channelListEnd:
            // Nowhere, not even the status window. The canvas is the whole destination,
            // and `handle(_:)` returns before this for the same reason.
            return []

        case .numeric(_, let parameters):
            // **A numeric that names a channel you have open belongs in that channel.**
            // Before this, every numeric went to the status window — so typing into a `+m`
            // or `+r` channel produced `Cannot send to nick/channel` two windows away, and
            // the channel itself showed nothing at all: no echo, no error, the message
            // simply gone. Found by somebody asking whether they needed permission to
            // speak, which is exactly the question that failure provokes.
            if let channel = channelNamed(in: parameters) { return [channel] }
            return [status]

        case .stateChanged, .registered, .clientError, .clientNotice, .raw,
            .namesReply, .endOfNames, .channelChanged, .channelClosed,
            .capabilitiesChanged, .authenticated, .standardReply,
            .batchStarted, .batchEnded, .bouncerNetworks,
            // Presence is about somebody who may be in no channel of ours at all, and our
            // own away state is about the connection. Both are the network talking.
            .presenceChanged, .notifyBaseline, .awayStateChanged:
            return [status]
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
            .invited(_, _, let channel), .listModeEntry(let channel, _, _, _, _),
            .listModeEnd(let channel, _):
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
            .batchStarted, .batchEnded, .bouncerNetworks,
            // A notify list is nicks as the *user* typed them; nothing here was folded on
            // its way in, so there is no mapping to learn from it.
            .presenceChanged, .notifyBaseline, .awayStateChanged,
            // A 322's channel *was* folded under the live mapping, and learning from it
            // anyway would be twenty-two thousand assignments to an observed property —
            // which is twenty-two thousand invalidations of every view reading it. The
            // mapping is already known from `ISUPPORT` before any `LIST` can be asked for.
            .channelListEntry, .channelListEnd:
            break
        }
    }

    private func existing(_ name: IRCChannelName) -> ChannelBuffer? {
        buffersByName[name]
    }

    /// The open channel a numeric is about, if it names one.
    ///
    /// **The first and last parameters are skipped deliberately.** The first is always our
    /// own nick, and the last is the human-readable text — which routinely mentions a
    /// channel (`"You are not on #swift"`), and routing on prose would put a line in a
    /// window because of a sentence rather than because of a field. Everything between the
    /// two is the numeric's actual arguments, which is where a channel name is a channel
    /// name; a numeric with nothing between them has no argument to match on.
    private func channelNamed(in parameters: [String]) -> ChannelBuffer? {
        guard parameters.count > 2 else { return nil }
        for parameter in parameters[1..<(parameters.count - 1)] {
            if let buffer = existing(IRCChannelName(parameter, mapping: caseMapping)) {
                return buffer
            }
        }
        return nil
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
        reloadLog(into: buffer)
        channels.insert(
            buffer,
            at: bufferOrder?.insertionIndex(
                for: name.raw,
                among: channels.map(\.name.raw),
                network: networkKey,
                section: .channels
            ) ?? channels.count
        )
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
        reloadLog(into: buffer)
        queries.insert(
            buffer,
            at: bufferOrder?.insertionIndex(
                for: nick.raw,
                among: queries.map(\.nick.raw),
                network: networkKey,
                section: .queries
            ) ?? queries.count
        )
        return buffer
    }

    /// Puts the tail of a buffer's log back on screen as its window opens.
    ///
    /// **On creation, not on join.** The item calls this "reload last N lines on join", and
    /// a reconnect is the case it names — but a buffer survives a reconnect, so replaying on
    /// every `JOIN` would prepend the log to a window that already had the conversation in
    /// it. Creation is the moment there is genuinely nothing there, which is the first join
    /// after a launch. Everything the tail holds is remembered as a key first, which is what
    /// the `CHATHISTORY` covering the same period is reconciled against.
    ///
    /// Status windows are never reloaded. A replayed MOTD is not history, it is last week's
    /// connect, and the live one is about to arrive underneath it.
    private func reloadLog(into buffer: any ChatBuffer) {
        guard let chatLog, settings.logs(buffer), !(buffer is StatusBuffer) else { return }
        let count = settings.logReloadLines
        guard count > 0 else { return }
        let lines = chatLog.tail(count, network: networkKey, buffer: buffer.displayName)
        guard !lines.isEmpty else { return }

        var rendered: [AttributedString] = []
        rendered.reserveCapacity(lines.count)
        for text in lines {
            let logged = LoggedLine(text)
            if let key = logged.key { buffer.replay.remember(key) }
            rendered.append(renderer.line(logged.text, kind: .logReplay))
        }
        buffer.log.append(rendered)
    }

    private func removeBuffer(_ name: IRCChannelName) {
        guard buffersByName.removeValue(forKey: name) != nil else { return }
        channels.removeAll { $0.name == name }
    }
}
