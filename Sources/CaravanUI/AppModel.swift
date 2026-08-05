import Diagnostics
import Foundation
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
}

/// What is on screen: one connection at most, and whether the sheet is up.
///
/// Multiple networks are stage 2 by design — the sidebar grows a level and every window
/// gains an owner, and doing that before there is a single working one is how you get a
/// tree with nothing in it.
@MainActor
@Observable
public final class AppModel {
    public private(set) var connection: ConnectionViewModel?
    public var isShowingConnectSheet = false

    /// One trace buffer for the process. Redacted on insert; prompt 10 exports it.
    @ObservationIgnored public let trace = TraceBuffer()

    /// The sidebar item the user has selected. Only the status window exists at this
    /// stage; prompt 8 adds channels underneath.
    public var selection: SidebarItem?

    public enum SidebarItem: Hashable, Sendable {
        case status(UUID)
    }

    public init() {}

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
