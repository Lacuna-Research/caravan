import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import Observation

/// One connection, as the UI sees it: a status window, a lifecycle state, and a way to
/// type at the server.
///
/// Owns the event pump. Every event becomes at most one line in the status window, and
/// the pump runs on the main actor so appends need no hop of their own.
@MainActor
@Observable
public final class ConnectionViewModel: Identifiable {
    public let id = UUID()

    /// The status window's scrollback.
    public let log = MessageLogController()

    public private(set) var state: SessionState = .disconnected(reason: .notStarted)
    public private(set) var currentNick: String
    public let displayName: String

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

    /// A one-line summary for the sidebar and the window's status area.
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

    /// Sends a line typed into the input field.
    ///
    /// A stopgap: for now the text is sent as a raw IRC line, which is enough to `JOIN`
    /// and `PRIVMSG` by hand and prove the connection works end to end. Prompt 9 puts the
    /// command layer here — `/join`, plain text going to the current window's target, and
    /// the history and paste behaviour that go with it.
    public func send(rawLine text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let message = IRCMessage(line: trimmed) else {
            append(.clientError("could not parse: \(trimmed)"))
            return
        }
        log.append([LineRenderer.line(">> \(message.wireForm)", kind: .serverText)])
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
        switch event {
        case .stateChanged(let newState):
            state = newState
        case .registered(let info):
            currentNick = info.nick
        default:
            break
        }
        append(event)
    }

    private func append(_ event: IRCEvent) {
        guard let line = LineRenderer.line(for: event, ownNick: currentNick) else { return }
        log.append([line])
    }
}
