import Diagnostics
import Foundation
import IRCProtocol
import IRCSession
import IRCTransport
import Observation

/// What the user typed into the Connect sheet.
///
/// One field per `SessionConfiguration` value the sheet collects; timeouts and backoff
/// keep their defaults and want no UI.
public struct ConnectionSettings: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var useTLS: Bool
    public var nick: String
    public var altNick: String
    public var ident: String
    public var realName: String

    /// A server password, if the network or bouncer wants one.
    ///
    /// Held only long enough to reach the socket, and never written anywhere: it is not
    /// in the config file with the rest, because its home is the Keychain and that is
    /// stage 2's. A user re-types it per connection until then, which is the right
    /// failure mode.
    public var password: String

    public init(
        host: String = "irc.libera.chat",
        port: UInt16 = 6697,
        useTLS: Bool = true,
        nick: String = "",
        altNick: String = "",
        ident: String = "",
        realName: String = "",
        password: String = ""
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.nick = nick
        self.altNick = altNick
        self.ident = ident
        self.realName = realName
        self.password = password
    }

    public var sessionConfiguration: SessionConfiguration {
        SessionConfiguration(
            host: host,
            port: port,
            tls: useTLS ? .enabled(allowSelfSigned: false) : .disabled,
            nick: nick,
            altNick: altNick.isEmpty ? nil : altNick,
            ident: ident.isEmpty ? nil : ident,
            realName: realName.isEmpty ? nil : realName,
            password: password.isEmpty ? nil : password
        )
    }

    /// Whether the sheet has enough to connect.
    public var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !nick.trimmingCharacters(in: .whitespaces).isEmpty
            && port > 0
    }

    /// Config-file keys, named once.
    ///
    /// Two readers — the Connect sheet writes them and `/server` reads them — and a key
    /// that is a string literal in two places is a key that eventually differs in one.
    public enum Key {
        public static let host = "server.host"
        public static let port = "server.port"
        public static let useTLS = "server.tls"
        public static let nick = "server.nick"
        public static let altNick = "server.alt-nick"
        public static let ident = "server.ident"
        public static let realName = "server.real-name"
    }

    /// The last values the Connect sheet was used with.
    ///
    /// `/server` changes the host and nothing else — identity belongs to the client's
    /// settings, and a command that silently changed your nick or real name would be a
    /// surprise. The password is absent by design: its home is the Keychain, and until
    /// that exists it is never written down.
    @MainActor
    public static func lastUsed(from config: ConfigFile = .shared) -> ConnectionSettings {
        ConnectionSettings(
            host: config.string(Key.host) ?? "irc.libera.chat",
            port: config.int(Key.port).map { UInt16(clamping: $0) } ?? 6697,
            useTLS: config.bool(Key.useTLS) ?? true,
            nick: config.string(Key.nick) ?? "",
            altNick: config.string(Key.altNick) ?? "",
            ident: config.string(Key.ident) ?? "",
            realName: config.string(Key.realName) ?? ""
        )
    }

    /// Records these as the last-used values. Called on connecting rather than on every
    /// keystroke: "last used" should mean used, not merely typed and cancelled.
    @MainActor
    public func rememberAsLastUsed(in config: ConfigFile = .shared) {
        config.set(host, forKey: Key.host)
        config.set(Int(port), forKey: Key.port)
        config.set(useTLS, forKey: Key.useTLS)
        config.set(nick, forKey: Key.nick)
        config.set(altNick.isEmpty ? nil : altNick, forKey: Key.altNick)
        config.set(ident.isEmpty ? nil : ident, forKey: Key.ident)
        config.set(realName.isEmpty ? nil : realName, forKey: Key.realName)
    }
}

/// What is on screen: one connection at most, and whether the sheet is up.
///
/// The tree already has its settled shape — channels nested under their network, always,
/// because `#music` on Efnet and `#music` on Undernet are different rooms and any
/// structure that cannot say which one you are looking at is broken. What stage 2 adds is
/// a *second* network beside the first, not a new level.
@MainActor
@Observable
public final class AppModel {
    public private(set) var connection: ConnectionViewModel?
    public var isShowingConnectSheet = false

    /// One trace buffer for the process. Redacted on insert, exported by "Copy
    /// Diagnostics" — which is what makes the export safe to paste into a public issue.
    @ObservationIgnored public let trace: TraceBuffer

    /// Appearance, shared by every buffer of every connection. Settings are global
    /// first; per-window overrides are a later addition if anyone wants them.
    @ObservationIgnored public let settings: ChatSettings

    /// The plain-text config both the settings form and the Connect sheet persist to.
    @ObservationIgnored public let config: ConfigFile

    /// Where the wire trace is going. Lives on the app rather than the connection: the
    /// trace is one ring for the process, and `/debug` outlives any single connection.
    @ObservationIgnored public let debug: DebugController

    /// The tree row the user has selected.
    ///
    /// Changing it draws the unread rule in the buffer being *left*, which is what makes
    /// the rule mean "everything above this you have seen".
    public var selection: SidebarItem? {
        didSet { markUnread(leaving: oldValue) }
    }

    /// Whether the network's children are showing. One network at this stage, so one
    /// flag; stage 2's multi-network tree gives each its own.
    public var isNetworkExpanded = true

    /// One selectable row in the tree.
    ///
    /// There is no separate status row: the network row *is* the status buffer's entry,
    /// which removes a row per network and a concept from the UI.
    ///
    /// Note what this enum is named after. It is a *row*, not a buffer: `settingsAndDebug`
    /// is a canvas, has no activity state, and takes no part in buffer navigation — but it
    /// is selectable in the tree, because the tree is a navigation list rather than
    /// strictly a list of buffers (GUI-DESIGN-NOTES.md §10).
    public enum SidebarItem: Hashable, Sendable {
        case status(UUID)
        case channel(connection: UUID, channel: IRCChannelName)
        case settingsAndDebug
    }

    /// Whether the canvas is what the detail area is showing.
    public var isShowingCanvas: Bool { selection == .settingsAndDebug }

    /// ⌘0, ⌘, and the pinned row all land here.
    public func showSettingsAndDebug() {
        selection = .settingsAndDebug
    }

    /// The config file is injectable so a test can point it at a temporary directory
    /// rather than writing into the settings of whoever is running the suite.
    public init(config: ConfigFile = .shared, settings: ChatSettings? = nil) {
        let settings = settings ?? ChatSettings(config: config)
        let trace = TraceBuffer()
        self.config = config
        self.settings = settings
        self.trace = trace
        self.debug = DebugController(trace: trace, settings: settings)
    }

    /// The channel the selection names, when it names one.
    public var selectedChannel: ChannelBuffer? {
        guard case .channel(let connectionID, let name) = selection,
            let connection, connection.id == connectionID
        else { return nil }
        return connection.buffer(named: name)
    }

    /// Closes the selected channel buffer, parting the channel. ⌘W's action.
    public func closeSelectedChannel() async {
        guard let buffer = selectedChannel, let connection else { return }
        await connection.closeChannel(buffer.name)
        selection = .status(connection.id)
    }

    // MARK: - Input

    /// Runs a box full of input through the command layer and carries out what it asks.
    ///
    /// One switch, here, rather than half of it on the connection: `/server` points the
    /// *app* at a new host, and a connection cannot replace itself. Everything else is
    /// the connection's, and this hands it straight over.
    public func submit(_ text: String, from target: Target?) async {
        guard let connection else { return }
        for action in await connection.actions(for: text, activeTarget: target) {
            switch action {
            case .send(let message):
                await connection.send(message, from: target)
            case .error(let message):
                connection.showError(message, in: target)
            case .reconnect:
                await connection.connect()
            case .disconnect:
                await connection.disconnect()
            case .quit(let reason):
                await connection.quit(reason: reason)
            case .connect(let host, let port, let tls, let password):
                await connect(
                    toHost: host,
                    port: port,
                    tls: tls,
                    password: password,
                    reportingInto: target
                )
            case .debug(let command):
                // The canvas is where `/debug window` sends output, so the command opens
                // it: being told the trace is now going somewhere you cannot see would be
                // a strange way to answer.
                let answer = debug.apply(command)
                if case .toCanvas = command { showSettingsAndDebug() }
                connection.showNotice(answer, in: target)
            }
        }
    }

    /// `/server` and `/connect <host>`: the stored identity, pointed somewhere new.
    private func connect(
        toHost host: String,
        port: UInt16?,
        tls: Bool?,
        password: String?,
        reportingInto target: Target?
    ) async {
        var settings = ConnectionSettings.lastUsed(from: config)
        settings.host = host
        if let port { settings.port = port }
        if let tls { settings.useTLS = tls }
        if let password { settings.password = password }

        guard settings.isValid else {
            // The one thing `/server` cannot supply. Said out loud rather than failing
            // quietly, which is the same rule every other argument error follows.
            connection?.showError(
                "/server has no nickname to use — set one in the Connect sheet first",
                in: target
            )
            return
        }
        await connect(using: settings)
    }

    public func connect(using settings: ConnectionSettings) async {
        settings.rememberAsLastUsed(in: config)
        await connection?.disconnect()
        let connection = ConnectionViewModel(
            configuration: settings.sessionConfiguration,
            trace: trace,
            settings: self.settings
        )
        self.connection = connection
        selection = .status(connection.id)
        await connection.connect()
    }

    // MARK: - Settings

    /// Pushes changed settings out to everything already on screen.
    ///
    /// The settings form calls this; nothing observes `ChatSettings` for it. An
    /// `@Observable` read inside a view redraws the view, but the font and the line cap
    /// live on `MessageLogController`s that no view owns — so this is the one push, and
    /// it is explicit rather than a chain of observers to reason about.
    public func applySettings() {
        connection?.applySettings()
        debug.applySettings()
    }

    // MARK: - Completion

    /// What Tab completes against in a given window.
    ///
    /// Assembled here because it is the one place that can see all three sources at once:
    /// the buffer's membership, the connection's open channels, and the command table.
    /// Nothing in it needs a round trip — completing against anything the server would
    /// have to be asked for is the line this stage does not cross.
    public func completionSources(in buffer: ChannelBuffer?) -> CompletionSources {
        CompletionSources(
            // The nick list's own order, which is rank then casemapped alphabetical.
            nicks: buffer?.members.map(\.nick.raw) ?? [],
            channels: connection?.channels.map(\.name.raw) ?? [],
            commands: CompletionSources.allCommands
        )
    }

    // MARK: - Diagnostics

    /// Puts the redacted wire trace, plus the app and OS version, on the clipboard.
    @MainActor
    public func copyDiagnostics() {
        DiagnosticsReport.copyToPasteboard(trace: trace)
    }

    // MARK: - The unread rule

    /// Draws the rule in the buffer being left behind.
    ///
    /// Only on the way out. A rule drawn on arrival would sit at the bottom of a buffer
    /// you are looking at, marking nothing; drawn on the way out it marks the last thing
    /// you saw, and it stays there until the next time you leave.
    private func markUnread(leaving previous: SidebarItem?) {
        guard let previous, previous != selection, let connection else { return }
        let renderer = settings.renderer
        switch previous {
        case .status(let id) where id == connection.id:
            connection.log.markUnreadPosition(with: renderer.unreadRule())
        case .channel(let id, let name) where id == connection.id:
            connection.buffer(named: name)?.log.markUnreadPosition(with: renderer.unreadRule())
        default:
            break
        }
    }

    public func disconnect() async {
        await connection?.disconnect()
    }
}
