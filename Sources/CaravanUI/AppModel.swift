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
    /// in `@AppStorage` with the rest, because its home is the Keychain and that is
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

    /// `@AppStorage` keys, named once.
    ///
    /// Two readers now — the Connect sheet writes them and `/server` reads them — and a
    /// key that is a string literal in two places is a key that eventually differs in one.
    public enum Key {
        public static let host = "lastHost"
        public static let port = "lastPort"
        public static let useTLS = "lastUseTLS"
        public static let nick = "lastNick"
        public static let altNick = "lastAltNick"
        public static let ident = "lastIdent"
        public static let realName = "lastRealName"
    }

    /// The last values the Connect sheet was used with.
    ///
    /// `/server` changes the host and nothing else — identity belongs to the client's
    /// settings, and a command that silently changed your nick or real name would be a
    /// surprise. The password is absent by design: its home is the Keychain, and until
    /// that exists it is never written down.
    public static var lastUsed: ConnectionSettings {
        let defaults = UserDefaults.standard
        let storedPort = defaults.integer(forKey: Key.port)
        return ConnectionSettings(
            host: defaults.string(forKey: Key.host) ?? "irc.libera.chat",
            port: storedPort > 0 ? UInt16(clamping: storedPort) : 6697,
            useTLS: defaults.object(forKey: Key.useTLS) as? Bool ?? true,
            nick: defaults.string(forKey: Key.nick) ?? "",
            altNick: defaults.string(forKey: Key.altNick) ?? "",
            ident: defaults.string(forKey: Key.ident) ?? "",
            realName: defaults.string(forKey: Key.realName) ?? ""
        )
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

    /// One trace buffer for the process. Redacted on insert; prompt 10 exports it.
    @ObservationIgnored public let trace = TraceBuffer()

    /// The tree row the user has selected.
    public var selection: SidebarItem?

    /// Whether the network's children are showing. One network at this stage, so one
    /// flag; stage 2's multi-network tree gives each its own.
    public var isNetworkExpanded = true

    /// One selectable row in the tree.
    ///
    /// There is no separate status row: the network row *is* the status buffer's entry,
    /// which removes a row per network and a concept from the UI.
    public enum SidebarItem: Hashable, Sendable {
        case status(UUID)
        case channel(connection: UUID, channel: IRCChannelName)
    }

    public init() {}

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
        var settings = ConnectionSettings.lastUsed
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
        await connection?.disconnect()
        let connection = ConnectionViewModel(
            configuration: settings.sessionConfiguration,
            trace: trace
        )
        self.connection = connection
        selection = .status(connection.id)
        await connection.connect()
    }

    public func disconnect() async {
        await connection?.disconnect()
    }
}
