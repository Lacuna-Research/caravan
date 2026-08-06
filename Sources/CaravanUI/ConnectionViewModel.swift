import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
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
    public let displayName: String

    /// Channel buffers in join order, which is the order the tree shows them in.
    public private(set) var channels: [ChannelBuffer] = []

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

    /// The casemapping the session is folding names under, learned from the events that
    /// carry one. Starts at the `ISUPPORT` default, as the session's own does.
    @ObservationIgnored private var caseMapping: IRCCaseMapping = .rfc1459

    @ObservationIgnored private let session: IRCSession
    @ObservationIgnored private var pump: Task<Void, Never>?

    public init(
        configuration: SessionConfiguration,
        trace: TraceBuffer,
        settings: ChatSettings = ChatSettings()
    ) {
        self.session = IRCSession(configuration: configuration, trace: trace)
        self.currentNick = configuration.nick
        self.displayName = configuration.host
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

    /// Sends a message, echoing what we said into the window it came from.
    ///
    /// **Local echo, because there is no `echo-message` yet.** Without the capability the
    /// server does not send our own messages back, so a client that only rendered inbound
    /// traffic would never show what you typed. The line is marked `own*`, which is the
    /// one bit stage 2 needs to suppress the duplicate once the capability is negotiated.
    ///
    /// The wire form goes to the status window instead, and only when the raw-traffic
    /// toggle is on — that is where `>>` markers belong.
    public func send(_ message: IRCMessage, from target: Target?) async {
        appendRaw(message.wireForm, kind: .rawOutbound)
        if let echo = selfEchoLine(for: message, in: target) {
            log(for: target).append([echo])
        }
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
        for controller in [log] + channels.map(\.log) {
            controller.chatFont = font
            controller.lineCap = settings.scrollbackLines
            controller.palette = palette
        }
    }

    /// The line for a message we just sent, or `nil` for anything that is not one.
    ///
    /// `PRIVMSG` and `NOTICE` only. A `JOIN` or a `MODE` produces no echo because the
    /// server will tell us about it in a moment, and echoing it here would show it twice.
    ///
    /// **A message addressed somewhere other than this window is marked as such.** `/msg
    /// bob hi` typed in `#swift` echoes there — mIRC's behaviour, and the only way to see
    /// that it sent without leaving the window — but as `-> *bob* hi`, with the recipient
    /// in the nick column. The live acceptance run found it rendered as `<@you> hi`,
    /// indistinguishable from something said in the channel, which is a client lying about
    /// where your words went.
    private func selfEchoLine(for message: IRCMessage, in target: Target?) -> AttributedString? {
        guard case .verb(let verb) = message.command, message.parameters.count >= 2 else {
            return nil
        }
        let isNotice: Bool
        switch verb.uppercased() {
        case "PRIVMSG": isNotice = false
        case "NOTICE": isNotice = true
        default: return nil
        }

        let (text, isAction) = EventTranslator.unwrapAction(message.parameters[1])
        let recipient = message.parameters[0]
        var fields = LineFields()
        fields.text = text

        guard isThisWindow(recipient, target) else {
            fields.nick = recipient
            return renderer.line(
                kind: isNotice ? .ownPrivateNotice : .ownPrivateMessage,
                fields: fields
            )
        }

        fields.nick = ownDisplayName(in: target)
        let kind: LineKind =
            isAction ? .ownAction : (isNotice ? .ownNotice : .ownMessage)
        return renderer.line(kind: kind, fields: fields)
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
        guard case .channel(let name)? = target else { return log }
        return buffersByName[name]?.log ?? log
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
        default:
            break
        }
        append(event)
    }

    private func append(_ event: IRCEvent) {
        // Every inbound line has somewhere to land, whether or not it was understood.
        if case .raw(let message) = event {
            appendRaw(message.wireForm, kind: .rawInbound)
            return
        }
        let context = RenderContext(
            ownNick: currentNick,
            senderPrefix: senderPrefix(for: event)
        )
        guard let line = renderer.line(for: event, context: context) else { return }
        for destination in destinations(for: event) {
            destination.append([line])
        }
    }

    /// The prefix the sender of a channel message holds there, e.g. `@`.
    ///
    /// Only messages have a nick column, and a message has exactly one channel, so there
    /// is no ambiguity about which buffer to ask.
    private func senderPrefix(for event: IRCEvent) -> Character? {
        guard case .message(let target, let sender, _, _, _) = event,
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
        case .joined(let channel, let who):
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

        case .modeChanged(let target, _, _), .message(let target, _, _, _, _):
            guard case .channel(let name) = target else { return [log] }
            return [existing(name) ?? log]

        case .quit(let who, _):
            return buffersContaining(nick: who.nick).map(\.log)

        case .nickChanged(let who, _):
            let shared = buffersContaining(nick: who.nick).map(\.log)
            // Our own rename is news everywhere, including where we share no channel.
            let isOwnRename = who.nick.map { isOwn(nick: $0) } == true
            return isOwnRename || shared.isEmpty ? [log] + shared : shared

        case .stateChanged, .registered, .numeric, .clientError, .raw,
            .namesReply, .endOfNames, .channelChanged, .channelClosed:
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
        case .joined(let channel, _), .parted(let channel, _, _),
            .kicked(let channel, _, _, _), .topicChanged(let channel, _, _),
            .topicAuthor(let channel, _, _), .channelModes(let channel, _),
            .namesReply(let channel, _), .endOfNames(let channel),
            .joinFailed(let channel, _, _), .channelClosed(let channel):
            caseMapping = channel.mapping
        case .channelChanged(let channel):
            caseMapping = channel.mapping
        case .message(let target, _, _, _, _), .modeChanged(let target, _, _):
            if case .channel(let name) = target { caseMapping = name.mapping }
        case .raw, .stateChanged, .registered, .quit, .nickChanged, .numeric, .clientError:
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

    private func removeBuffer(_ name: IRCChannelName) {
        guard buffersByName.removeValue(forKey: name) != nil else { return }
        channels.removeAll { $0.name == name }
    }
}
