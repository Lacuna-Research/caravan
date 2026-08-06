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
    /// Never written to `caravan.conf`. Its home is the macOS Keychain, and it is read
    /// back from there when the sheet opens — which is what stops it being re-typed every
    /// session.
    public var password: String

    /// How to authenticate, if at all.
    public var authentication: AuthenticationChoice = .none
    public var account = ""
    /// The SASL or NickServ password. Keychain, like ``password``.
    public var accountPassword = ""
    /// The Keychain label of the client certificate SASL `EXTERNAL` presents.
    public var certificateLabel = ""

    /// The authentication methods the Connect sheet offers.
    ///
    /// A flat list rather than SASL-with-a-mechanism-underneath: what a user picks is one
    /// thing, and a two-level control for four options is a menu inside a menu.
    public enum AuthenticationChoice: String, Sendable, CaseIterable, Identifiable {
        case none
        case saslPlain = "sasl-plain"
        case saslExternal = "sasl-external"
        case saslScram = "sasl-scram-sha-256"
        case nickServ = "nickserv"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .none: "None"
            case .saslPlain: "SASL PLAIN"
            case .saslExternal: "SASL EXTERNAL (client certificate)"
            case .saslScram: "SASL SCRAM-SHA-256"
            case .nickServ: "NickServ IDENTIFY"
            }
        }

        var mechanism: SASLMechanism? {
            switch self {
            case .none, .nickServ: nil
            case .saslPlain: .plain
            case .saslExternal: .external
            case .saslScram: .scramSHA256
            }
        }

        /// Whether a password field makes sense for this choice.
        public var needsPassword: Bool {
            switch self {
            case .none, .saslExternal: false
            case .saslPlain, .saslScram, .nickServ: true
            }
        }

        public var needsAccount: Bool { self != .none }
    }

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

    /// **TLS defaults to trust-on-first-use, not to bare system validation.**
    ///
    /// The two differ only for a certificate the system will not validate, which used to
    /// fail the connection outright with nothing to say beyond a Network.framework error
    /// string. Now the user is shown the fingerprint and asked. That is strictly more
    /// permissive than refusing and strictly less permissive than the `allowSelfSigned`
    /// flag it replaces, which accepted without asking anyone.
    public var sessionConfiguration: SessionConfiguration {
        SessionConfiguration(
            host: host,
            port: port,
            tls: useTLS ? .enabled(.trustOnFirstUse) : .disabled,
            nick: nick,
            altNick: altNick.isEmpty ? nil : altNick,
            ident: ident.isEmpty ? nil : ident,
            realName: realName.isEmpty ? nil : realName,
            password: password.isEmpty ? nil : password,
            authentication: authenticationMethod
        )
    }

    var authenticationMethod: AuthenticationMethod {
        switch authentication {
        case .none:
            return .none
        case .nickServ:
            guard !account.isEmpty, !accountPassword.isEmpty else { return .none }
            return .nickServ(account: account, password: accountPassword)
        case .saslPlain, .saslExternal, .saslScram:
            guard let mechanism = authentication.mechanism else { return .none }
            // A mechanism that needs a password and has none is not authentication, it is
            // a failed connection waiting to happen; better to connect unauthenticated and
            // say so than to abort every attempt until the field is filled in.
            if mechanism.needsPassword, account.isEmpty || accountPassword.isEmpty {
                return .none
            }
            return .sasl(mechanism: mechanism, account: account, password: accountPassword)
        }
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
        public static let authentication = "server.authentication"
        public static let account = "server.account"
        public static let certificateLabel = "server.client-certificate"
    }

    /// The last values the Connect sheet was used with.
    ///
    /// `/server` changes the host and nothing else — identity belongs to the client's
    /// settings, and a command that silently changed your nick or real name would be a
    /// surprise.
    ///
    /// **The two passwords come from the Keychain, keyed on the host**, and everything
    /// else comes from `caravan.conf`. That split is the whole of the rule: the config
    /// file records the *shape* of the credential — which host, which account, which
    /// mechanism — and never the secret itself.
    @MainActor
    public static func lastUsed(
        from config: ConfigFile = .shared,
        credentials: any CredentialStore = Keychain.shared
    ) -> ConnectionSettings {
        var settings = ConnectionSettings(
            host: config.string(Key.host) ?? "irc.libera.chat",
            port: config.int(Key.port).map { UInt16(clamping: $0) } ?? 6697,
            useTLS: config.bool(Key.useTLS) ?? true,
            nick: config.string(Key.nick) ?? "",
            altNick: config.string(Key.altNick) ?? "",
            ident: config.string(Key.ident) ?? "",
            realName: config.string(Key.realName) ?? ""
        )
        settings.authentication =
            config.string(Key.authentication).flatMap(AuthenticationChoice.init(rawValue:))
            ?? .none
        settings.account = config.string(Key.account) ?? ""
        settings.certificateLabel = config.string(Key.certificateLabel) ?? ""
        settings.loadSecrets(from: credentials)
        return settings
    }

    /// Fills the two password fields from the credential store for whatever host is set.
    ///
    /// Separate from ``lastUsed(from:credentials:)`` so that changing the host in the sheet
    /// can pull that host's credentials rather than the previous host's.
    @MainActor
    public mutating func loadSecrets(from credentials: any CredentialStore = Keychain.shared) {
        password = credentials.password(.serverPassword, host: host) ?? ""
        accountPassword = credentials.password(.account, host: host) ?? ""
    }

    /// Records these as the last-used values. Called on connecting rather than on every
    /// keystroke: "last used" should mean used, not merely typed and cancelled.
    ///
    /// The secrets go to the Keychain in the same breath, which is what stops the password
    /// field being re-typed every session. An emptied field deletes the stored item rather
    /// than storing an empty string, so clearing it really does forget.
    @MainActor
    public func rememberAsLastUsed(
        in config: ConfigFile = .shared,
        credentials: any CredentialStore = Keychain.shared
    ) {
        config.set(host, forKey: Key.host)
        config.set(Int(port), forKey: Key.port)
        config.set(useTLS, forKey: Key.useTLS)
        config.set(nick, forKey: Key.nick)
        config.set(altNick.isEmpty ? nil : altNick, forKey: Key.altNick)
        config.set(ident.isEmpty ? nil : ident, forKey: Key.ident)
        config.set(realName.isEmpty ? nil : realName, forKey: Key.realName)
        config.set(
            authentication == .none ? nil : authentication.rawValue,
            forKey: Key.authentication
        )
        config.set(account.isEmpty ? nil : account, forKey: Key.account)
        config.set(
            certificateLabel.isEmpty ? nil : certificateLabel,
            forKey: Key.certificateLabel
        )

        credentials.setPassword(password, .serverPassword, host: host)
        credentials.setPassword(accountPassword, .account, host: host)
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

    /// TLS fingerprints the user has already accepted.
    @ObservationIgnored public let knownHosts: KnownHosts

    /// Where passwords are kept. The Keychain in the app, something ephemeral in a test.
    @ObservationIgnored public let credentials: any CredentialStore

    /// A certificate the system would not validate, waiting on the user.
    ///
    /// The connection is genuinely blocked on this: the TLS verify block is holding its
    /// completion handler open, so the handshake does not proceed either way until the
    /// sheet is answered.
    public var pendingTrust: TrustRequest?

    /// One certificate, and somewhere to put the answer.
    public struct TrustRequest: Identifiable {
        public let id = UUID()
        public let certificate: TLSCertificate
        public let host: String
        /// A fingerprint we remembered for this host that is *not* the one presented.
        ///
        /// The dangerous case, and it reads differently from a first visit: a certificate
        /// that changed is either a rotation or an interception, and the user is the only
        /// one who can tell which.
        public let previousFingerprint: String?
        let respond: (Bool) -> Void

        public func answer(_ trusted: Bool) {
            respond(trusted)
        }
    }

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
    /// rather than writing into the settings of whoever is running the suite. The known
    /// hosts file and the credential store are injectable for the same reason — with more
    /// force for the last of the three, since the alternative is a test suite that leaves
    /// passwords in the developer's login keychain.
    public init(
        config: ConfigFile = .shared,
        settings: ChatSettings? = nil,
        knownHosts: KnownHosts? = nil,
        credentials: (any CredentialStore)? = nil
    ) {
        let settings = settings ?? ChatSettings(config: config)
        let trace = TraceBuffer()
        self.config = config
        self.settings = settings
        self.trace = trace
        self.knownHosts = knownHosts ?? .shared
        self.credentials = credentials ?? Keychain.shared
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
        var settings = ConnectionSettings.lastUsed(from: config, credentials: credentials)
        settings.host = host
        // Re-read the Keychain for the *new* host: `lastUsed` filled the fields from the
        // previous one, and sending that host's password to a different server is exactly
        // the mistake a credential store exists to prevent.
        settings.loadSecrets(from: credentials)
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
        settings.rememberAsLastUsed(in: config, credentials: credentials)
        await connection?.disconnect()
        let connection = ConnectionViewModel(
            configuration: settings.sessionConfiguration,
            trace: trace,
            settings: self.settings,
            credentials: credentials(for: settings)
        )
        self.connection = connection
        selection = .status(connection.id)
        await connection.connect()
    }

    // MARK: - TLS

    /// The trust evaluator and client certificate for one connection.
    private func credentials(for settings: ConnectionSettings) -> TLSCredentials {
        TLSCredentials(
            trustEvaluator: { [weak self] certificate, host in
                await self?.decideTrust(certificate, host: host) ?? false
            },
            // Looked up per connection rather than held: a certificate can be added to the
            // Keychain while the app is running, and requiring a relaunch to notice would
            // be a strange thing to make someone do.
            clientIdentity: ClientCertificate.identity(labelled: settings.certificateLabel)
        )
    }

    /// Trust-on-first-use: accept what we accepted before, ask about anything else.
    ///
    /// Runs on the main actor because its answer may be a sheet. Everything below it is
    /// waiting — the TLS handshake is genuinely paused on this call — which is why there is
    /// no timeout here: a dialog nobody answered should leave the connection hanging
    /// visibly rather than failing on its own after a while and blaming the network.
    func decideTrust(_ certificate: TLSCertificate, host: String) async -> Bool {
        let remembered = knownHosts.fingerprint(for: host)
        if remembered == certificate.sha256Fingerprint { return true }

        let accepted = await withCheckedContinuation { continuation in
            pendingTrust = TrustRequest(
                certificate: certificate,
                host: host,
                previousFingerprint: remembered,
                respond: { continuation.resume(returning: $0) }
            )
        }
        pendingTrust = nil
        if accepted {
            knownHosts.remember(certificate.sha256Fingerprint, for: host)
        }
        return accepted
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
