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

    @ObservationIgnored private var buffersByName: [IRCChannelName: ChannelBuffer] = [:]

    /// The casemapping the session is folding names under, learned from the events that
    /// carry one. Starts at the `ISUPPORT` default, as the session's own does.
    @ObservationIgnored private var caseMapping: IRCCaseMapping = .rfc1459

    @ObservationIgnored private let session: IRCSession
    @ObservationIgnored private var pump: Task<Void, Never>?

    public init(configuration: SessionConfiguration, trace: TraceBuffer) {
        self.session = IRCSession(configuration: configuration, trace: trace)
        self.currentNick = configuration.nick
        self.displayName = configuration.host
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

    /// Sends a line typed into the input field, echoing it into the buffer it came from.
    ///
    /// A stopgap: for now the text is sent as a raw IRC line, which is enough to `JOIN`
    /// and `PRIVMSG` by hand and prove the connection works end to end. Prompt 9 puts the
    /// command layer here — `/join`, plain text going to the current window's target, and
    /// the history and paste behaviour that go with it.
    public func send(rawLine text: String, from channel: IRCChannelName? = nil) async {
        let destination = channel.flatMap { buffersByName[$0]?.log } ?? log
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let message = IRCMessage(line: trimmed) else {
            destination.append(
                [LineRenderer.line("*** could not parse: \(trimmed)", kind: .clientError)]
            )
            return
        }
        destination.append([LineRenderer.line(">> \(message.wireForm)", kind: .serverText)])
        await session.send(message)
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
        default:
            break
        }
        append(event)
    }

    private func append(_ event: IRCEvent) {
        guard let line = LineRenderer.line(for: event, ownNick: currentNick) else { return }
        for destination in destinations(for: event) {
            destination.append([line])
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
        buffersByName[name] = buffer
        channels.append(buffer)
        return buffer
    }

    private func removeBuffer(_ name: IRCChannelName) {
        guard buffersByName.removeValue(forKey: name) != nil else { return }
        channels.removeAll { $0.name == name }
    }
}
