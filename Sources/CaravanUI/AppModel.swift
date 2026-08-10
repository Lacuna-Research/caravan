import AppKit
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

    /// The bouncer network to reach through this connection, for a bouncer that cannot do
    /// `soju.im/bouncer-networks`.
    ///
    /// **The documented fallback, and the older way every bouncer supports:** the network
    /// goes in the username as `<user>/<network>`, so one connection per network is opened
    /// by hand rather than discovered. `ZNC` and an old soju both work this way, and it is
    /// how a stage-1 client reached soju at all.
    ///
    /// Empty for a direct connection, and for a bouncer that *can* enumerate — there the
    /// networks are found rather than typed, and `SessionConfiguration.bouncerNetworkID`
    /// carries the binding instead.
    public var bouncerNetwork = ""

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
            ident: bouncerIdent,
            realName: realName.isEmpty ? nil : realName,
            password: password.isEmpty ? nil : password,
            authentication: authenticationMethod,
            clientVersion: Self.clientVersion
        )
    }

    /// What CTCP `VERSION` answers with.
    ///
    /// Read from the bundle here rather than in `IRCSession`, which has no bundle and no
    /// business acquiring one. The OS version is included because "which macOS" is the
    /// first question asked of a client-specific bug, and CTCP `VERSION` is where every
    /// other client has put it for thirty years.
    ///
    /// Assembled from the numeric components rather than from
    /// `operatingSystemVersionString`, which the live run showed reads `Version 26.5.2
    /// (Build 25F84)` — so the reply went out as "macOS Version 26.5.2 (Build 25F84)",
    /// with a redundant word and a build number nobody asking for a version wants.
    static var clientVersion: String {
        let short =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = short.map { "Caravan \($0)" } ?? "Caravan"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version) (macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))"
    }

    /// The `<user>` of `USER`, with the bouncer network appended when there is one.
    ///
    /// `alice/libera` is how a bouncer without `soju.im/bouncer-networks` is told which
    /// upstream to attach this connection to. It goes in the *ident* rather than anywhere
    /// else because that is where every bouncer looks for it.
    var bouncerIdent: String? {
        let user = ident.isEmpty ? nick : ident
        guard !bouncerNetwork.isEmpty else { return ident.isEmpty ? nil : ident }
        return "\(user)/\(bouncerNetwork)"
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
        public static let bouncerNetwork = "server.bouncer-network"
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
        settings.bouncerNetwork = config.string(Key.bouncerNetwork) ?? ""
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

    /// Writes the four identity fields, and nothing else.
    ///
    /// The Options Connect tab's setter. Separate from ``rememberAsLastUsed(in:credentials:)``
    /// because that one also writes the host, the port and the two Keychain secrets — which
    /// are per-server and none of a global identity form's business. Writes on every
    /// keystroke, like every other control on the canvas: there is no Apply button anywhere
    /// in this app, and identity is not where that starts.
    @MainActor
    public func rememberIdentity(in config: ConfigFile = .shared) {
        config.set(nick, forKey: Key.nick)
        config.set(altNick.isEmpty ? nil : altNick, forKey: Key.altNick)
        config.set(ident.isEmpty ? nil : ident, forKey: Key.ident)
        config.set(realName.isEmpty ? nil : realName, forKey: Key.realName)
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
        config.set(bouncerNetwork.isEmpty ? nil : bouncerNetwork, forKey: Key.bouncerNetwork)

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
    /// Every network, in the order it was opened.
    ///
    /// **One entry per network, whichever mode put it there.** A direct connection is one
    /// entry; a bouncer is one entry for the bouncer itself plus one per upstream network
    /// it is holding. Nothing below this line can tell the two apart, which is the whole
    /// test of the design — the tree, the selection, the command layer and the completion
    /// sources all see a flat list of networks.
    public private(set) var connections: [ConnectionViewModel] = []

    /// Whether ⌘K's palette is up.
    public var isShowingQuickSwitcher = false

    /// Whether the channel modes sheet is up, for the selected channel.
    public var isShowingChannelModes = false

    /// Every URL the client has drawn, and where each came from.
    ///
    /// On the app rather than per connection: "where did I see that link" is a question
    /// asked across networks as often as within one, and a catcher per connection would be
    /// three windows to search instead of one filter to change.
    public let urlCatcher = URLCatcher()

    /// Where the conversation is written down. One store for the whole app, since a log
    /// file is named by network and buffer rather than by connection — reconnecting to a
    /// network appends to the same file, which is the point.
    public let chatLog = ChatLog()

    /// Who you have stopped listening to. One list for the whole app: an ignore is global,
    /// not per network. See ``IgnoreList``.
    public let ignores: IgnoreList

    /// What counts as somebody talking to you. Global, like the ignore list and for the
    /// same reason. See ``HighlightRules``.
    public let highlights: HighlightRules

    /// Where an interruption goes. See ``Alerts``.
    public let alerts: Alerts

    /// The menu-bar item, which is off unless asked for.
    @ObservationIgnored public let menuBarItem = MenuBarItem()

    /// The people you want to know about. Global, like the ignore and highlight lists.
    public let notifyList: NotifyList

    /// The idle clock behind auto-away. One for the app: you are away from your desk, not
    /// from a particular network.
    @ObservationIgnored public let away: AwayController

    /// The log viewer, and which window it is a sheet on. Same reasoning as
    /// ``urlCatcherPresentation``: a plain flag would put the sheet on the main window even
    /// when a detached buffer asked for it.
    public var logViewerPresentation: LogViewerPresentation?

    /// Where a log viewer was opened from, which is the log it starts on.
    public struct LogViewerPresentation: Hashable, Sendable {
        public let window: KeyWindow
        public let network: String?
        public let buffer: String?
        /// What to put in the viewer's filter field when it opens.
        ///
        /// Carries ⌘F's search across to `Find in Log…`, so the second scope starts where
        /// the first one gave up rather than making the user type it twice.
        public let query: String?

        public init(window: KeyWindow, network: String?, buffer: String?, query: String? = nil) {
            self.window = window
            self.network = network
            self.buffer = buffer
            self.query = query
        }
    }

    /// The catcher window, and **which window it is a sheet on**.
    ///
    /// A plain `isShowing` flag would put the sheet on the main window even when it was
    /// asked for from a detached buffer — behind it, quite possibly. Recorded at the moment
    /// it is opened rather than read from ``keyWindow`` while presenting, because
    /// presenting a sheet is itself something that changes which window is key.
    public var urlCatcherPresentation: URLCatcherPresentation?

    /// Where a catcher window was opened from, which is what its scope filter starts on.
    public struct URLCatcherPresentation: Hashable, Sendable {
        public let window: KeyWindow
        public let network: String?
        public let buffer: String?

        public init(window: KeyWindow, network: String?, buffer: String?) {
            self.window = window
            self.network = network
            self.buffer = buffer
        }
    }

    /// Rows ejected into windows of their own (§1, §10), in the order they were ejected.
    ///
    /// Session state, not settings: which windows are open is the sort of thing macOS
    /// restores for itself, and writing it into `caravan.conf` would make a hand-edited
    /// file fight the window server.
    public internal(set) var detachedItems: [SidebarItem] = []

    /// A detached window the model wants raised, or closed. Set here and cleared by the
    /// view that acts on it — `openWindow` and `dismissWindow` are environment values, so
    /// only a `View` can call them, and the model must not reach for a `View`.
    public var windowToFocus: SidebarItem?
    public var windowToClose: SidebarItem?

    /// Which window the user is actually in front of.
    ///
    /// ⌘W means "close this channel" with the tree in front of you and "close this window"
    /// with a detached buffer in front of you. A global menu item cannot tell the
    /// difference without being told, and acting on the main window's selection while the
    /// user looks at a detached one would close a buffer they were not looking at.
    public var keyWindow: KeyWindow = .main

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

    /// Where the user has dragged each network's buffers (§12). Empty until they drag.
    public let bufferOrder: BufferOrder

    /// Which buffer each of ⌘1–9 reaches. Empty until the user binds something (§11).
    public let bindings: BufferBindings

    /// The servers the user keeps, in `servers.conf`. The app's front door (§13).
    public let servers: ServerList

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
    /// the rule mean "everything above this you have seen"; clears the activity state of
    /// the buffer being *entered*, which is what makes that state mean "since you last
    /// looked"; and records the visit for Ctrl+Tab's MRU order.
    public var selection: SidebarItem? {
        didSet {
            guard selection != oldValue else { return }
            markUnread(leaving: oldValue)
            if let selection {
                buffer(for: selection)?.activity = .none
                noteVisited(selection)
            }
            // The other half of what moves the badge: a raise puts one up, and looking at a
            // buffer takes one down.
            refreshAttentionSurfaces()
        }
    }

    /// Buffers in the order they were last looked at, most recent first. Ctrl+Tab's order.
    var recentBuffers: [SidebarItem] = []

    /// A Ctrl+Tab walk in progress, or `nil`. While one is, the MRU order is frozen.
    @ObservationIgnored var mruCycle: MRUCycle?

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
        /// A private conversation. Sorted after the channels of the same network (§12),
        /// which keeps channel positions stable as transient PMs come and go.
        case query(connection: UUID, nick: IRCNick)
        case settingsAndDebug
        /// The server list and the empty state (§13). A canvas like ``settingsAndDebug``,
        /// and a *peer row above* the networks rather than the root of the tree — the two
        /// canvases bracket the buffer list, which keeps the tree's root level meaningful.
        case dashboard
        /// What `/list` answers with, for one network.
        ///
        /// **A row per network, at the top of its group**, rather than the single pinned
        /// canvas this shipped as. The list is a property *of a network* — the same way its
        /// channels are — so the tree is where it belongs, and one row at the top of a group
        /// costs a great deal less than a picker the user has to find inside the canvas.
        case channelList(connection: UUID)
    }

    /// Whether the canvas is what the detail area is showing.
    public var isShowingCanvas: Bool { selection == .settingsAndDebug }

    /// Opens the Dashboard, or focuses its window when it has been ejected.
    ///
    /// The same shape as ``showSettingsAndDebug()`` and for the same reason (§10): once a
    /// canvas is in a window of its own, taking over the chat area instead would put it in
    /// two places at once.
    public func showDashboard() {
        if isDetached(.dashboard) {
            windowToFocus = .dashboard
            return
        }
        selection = .dashboard
    }

    /// Opens a network's channel list, or focuses its window when it has been ejected.
    ///
    /// **The network is decided before the selection moves.** `activeConnection` reads the
    /// selection, so asking it afterwards asks about the row we are on our way to — which is
    /// how this shipped opening a list that said "connect to a network" from a connected
    /// client. The row now carries its own network, which removes the question rather than
    /// answering it more carefully.
    public func showChannelList(on connection: ConnectionViewModel? = nil) {
        guard let id = (connection ?? activeConnection ?? connections.first)?.id else { return }
        let item = SidebarItem.channelList(connection: id)
        if isDetached(item) {
            windowToFocus = item
            return
        }
        selection = item
    }

    /// The connection a channel-list row is about.
    public func channelListConnection(of item: SidebarItem) -> ConnectionViewModel? {
        guard case .channelList(let id) = item else { return nil }
        return connection(id: id)
    }

    /// Whether `Find in Log…` has a buffer to search the log of.
    ///
    /// Disabled rather than absent when there is no buffer selected: a menu item that
    /// vanishes teaches nothing, and one that is greyed out says the feature exists.
    public var canSearchLog: Bool {
        guard activeConnection != nil else { return false }
        return selectedTarget != nil || selection.map(isStatusRow) == true
    }

    /// Opens the log viewer on the selected buffer, seeded with ⌘F's search string.
    ///
    /// **The string comes from the find pasteboard**, which is where macOS keeps it and
    /// where ⌘E writes it — `NSTextFinder` does not hand out its query, and reaching into
    /// the find bar's views for it would be reading somebody else's UI.
    public func showLogSearch() {
        guard let connection = activeConnection else { return }
        let buffer: String? =
            switch selectedTarget {
            case .channel(let name)?: name.raw
            case .nick(let nick)?: nick.raw
            case nil: connection.status.displayName
            }
        logViewerPresentation = LogViewerPresentation(
            window: .main,
            network: connection.networkKey,
            buffer: buffer,
            query: Self.findPasteboardString()
        )
    }

    static func findPasteboardString() -> String? {
        NSPasteboard(name: .find).string(forType: .string)
    }

    private func isStatusRow(_ item: SidebarItem) -> Bool {
        if case .status = item { return true }
        return false
    }

    /// Joins channels picked out of the channel list, and lands in the last one.
    ///
    /// **A channel already open is selected rather than re-joined.** Double-clicking a row
    /// for a window you are sitting in should take you there, not send a `JOIN` the server
    /// answers with 443. The window opens before the reply for the same reason
    /// `BufferBindings` opens one: the feedback belongs to the click.
    public func join(channels: [IRCChannelName], on connection: ConnectionViewModel) async {
        for name in channels {
            if connection.buffer(named: name) == nil {
                connection.openChannelBuffer(named: name)
                if connection.isConnected {
                    await connection.send(
                        IRCMessage(verb: "JOIN", parameters: [name.raw]),
                        from: nil
                    )
                }
            }
            selection = .channel(connection: connection.id, channel: name)
        }
    }

    // MARK: - Zoom

    /// ⌘+, ⌘− and ⌥⌘0 (§15.5). Global, never per window.
    ///
    /// **Multiplicative steps**, so zooming out and back in returns exactly where it
    /// started; adding and subtracting a constant drifts. `ChatSettings` clamps, so the
    /// ends of the range are where these stop rather than something to check here.
    public func zoomIn() { setZoom(settings.zoom * ChatSettings.zoomStep) }
    public func zoomOut() { setZoom(settings.zoom / ChatSettings.zoomStep) }
    public func resetZoom() { setZoom(ChatSettings.Default.zoom) }

    /// Whether zooming further would change anything, for enabling the menu items.
    public var canZoomIn: Bool { settings.zoom < ChatSettings.zoomRange.upperBound }
    public var canZoomOut: Bool { settings.zoom > ChatSettings.zoomRange.lowerBound }

    private func setZoom(_ value: Double) {
        settings.zoom = value
        applySettings()
    }

    /// ⌘0, ⌘, and the pinned row all land here.
    ///
    /// **Once the canvas is ejected, these focus its window rather than taking over the
    /// chat area** (§10). One place had to learn the difference and this is it — which is
    /// why both shortcuts and the tree's pinned row have always gone through one function.
    public func showSettingsAndDebug() {
        if isDetached(.settingsAndDebug) {
            windowToFocus = .settingsAndDebug
            return
        }
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
        credentials: (any CredentialStore)? = nil,
        servers: ServerList? = nil
    ) {
        let settings = settings ?? ChatSettings(config: config)
        let trace = TraceBuffer()
        let servers = servers ?? .shared
        self.config = config
        self.settings = settings
        self.trace = trace
        self.knownHosts = knownHosts ?? .shared
        self.credentials = credentials ?? Keychain.shared
        self.servers = servers
        // **Before the bindings are read**, which is the whole ordering constraint: they
        // parse the network out of `binding.N`, and reading them first would leave every
        // binding pointing at a `host:port` no connection answers to any more.
        Self.adoptLastUsedServer(config: config, servers: servers)
        NetworkKeyMigration.run(settings: config, servers: servers)
        self.bindings = BufferBindings(config: config)
        self.bufferOrder = BufferOrder(config: config)
        self.ignores = IgnoreList(config: config)
        self.highlights = HighlightRules(config: config)
        self.alerts = Alerts(settings: settings)
        self.notifyList = NotifyList(config: config)
        self.away = AwayController(settings: settings)
        self.debug = DebugController(trace: trace, settings: settings)
        // **The Dashboard is what you land on** (§13). It is the splash screen and the
        // empty state, which is the whole reason the app has no onboarding flow: the thing
        // a new user needs is a server list with an Add button, and that is the same thing
        // an existing user needs. Connecting moves the selection off it.
        self.selection = .dashboard
    }

    /// Turns a pre-server-list `caravan.conf` into a first entry.
    ///
    /// Before this prompt the only server anywhere was `server.host`/`server.port` — what
    /// the Connect sheet last used. Someone upgrading has one server they care about and it
    /// is that one, so an empty list plus a remembered host becomes an entry rather than an
    /// empty Dashboard and a shrug.
    ///
    /// It also keeps the test harness working: every acceptance run since prompt 3 has
    /// seeded `caravan.conf` and expected the app to know where to connect, and that trick
    /// would otherwise have died with the sheet. One rule covers both, which is why it is
    /// this rule rather than a special case for either.
    private static func adoptLastUsedServer(config: ConfigFile, servers: ServerList) {
        guard servers.entries.isEmpty,
            let host = config.string(ConnectionSettings.Key.host), !host.isEmpty
        else { return }
        let port = config.int(ConnectionSettings.Key.port).map { UInt16(clamping: $0) } ?? 6697
        let bouncer = config.string(ConnectionSettings.Key.bouncerNetwork) ?? ""
        let preferred =
            bouncer.isEmpty
            ? NetworkName.suggestion(forHost: host) : NetworkName.sanitised(bouncer)
        servers.save(
            ServerEntry(
                name: NetworkName.unique(preferred, taken: servers.names),
                host: host,
                port: port,
                useTLS: config.bool(ConnectionSettings.Key.useTLS) ?? true,
                authentication: config.string(ConnectionSettings.Key.authentication)
                    .flatMap(ConnectionSettings.AuthenticationChoice.init(rawValue:)) ?? .none,
                account: config.string(ConnectionSettings.Key.account) ?? "",
                certificateLabel: config.string(ConnectionSettings.Key.certificateLabel) ?? "",
                bouncerNetwork: bouncer
            )
        )
    }

    /// The connection a row belongs to.
    public func connection(id: UUID) -> ConnectionViewModel? {
        connections.first { $0.id == id }
    }

    /// The network the selection is in — the one a typed line goes to.
    ///
    /// Everything that used to reach for "the connection" now asks this, because with two
    /// networks open the question "which one" has an answer only the selection knows. The
    /// app-wide canvases have no network, and neither does an empty selection.
    ///
    /// **A channel-list row does**, unlike the other two canvases: it sits under a network in
    /// the tree and is about that network. It still has no ``selectedTarget`` — there is
    /// nothing to type into it — so this answers "which network am I looking at", not
    /// "where would a line go".
    public var activeConnection: ConnectionViewModel? {
        switch selection {
        case .status(let id): connection(id: id)
        case .channel(let id, _): connection(id: id)
        case .query(let id, _): connection(id: id)
        case .channelList(let id): connection(id: id)
        case .settingsAndDebug, .dashboard, nil: nil
        }
    }

    /// The channel the selection names, when it names one.
    public var selectedChannel: ChannelBuffer? {
        guard case .channel(let connectionID, let name) = selection,
            let connection = connection(id: connectionID)
        else { return nil }
        return connection.buffer(named: name)
    }

    /// The conversation the selection names, when it names one.
    public var selectedQuery: QueryBuffer? {
        guard case .query(let connectionID, let nick) = selection,
            let connection = connection(id: connectionID)
        else { return nil }
        return connection.query(named: nick)
    }

    /// Where a typed line goes from the selected window, or `nil` in a status window.
    public var selectedTarget: Target? {
        switch selection {
        case .channel(_, let name): .channel(name)
        case .query(_, let nick): .nick(nick)
        case .status, .settingsAndDebug, .dashboard, .channelList, nil: nil
        }
    }

    /// Whether ⌘W has a buffer to close, and what closing it is called.
    ///
    /// Two different acts behind one key: closing a channel *parts* it, and closing a
    /// conversation closes a window. The menu item says which, because a shortcut that
    /// quietly leaves a channel is one people press once.
    public var closeBufferTitle: String? {
        switch selection {
        case .channel: "Close Channel"
        case .query: "Close Conversation"
        case .status, .settingsAndDebug, .dashboard, .channelList, nil: nil
        }
    }

    /// Closes the selected buffer. ⌘W's action.
    ///
    /// A channel is parted — membership never outlives its buffer. A query is not, having
    /// no membership to leave; it simply stops taking up a row.
    public func closeSelectedBuffer() async {
        switch selection {
        case .channel(let connectionID, let name):
            guard let connection = connection(id: connectionID),
                let buffer = connection.buffer(named: name)
            else { return }
            await connection.closeChannel(buffer.name)
            selection = .status(connection.id)
        case .query(let connectionID, let nick):
            guard let connection = connection(id: connectionID) else { return }
            connection.closeQuery(nick)
            selection = .status(connection.id)
        case .status, .settingsAndDebug, .dashboard, .channelList, nil:
            return
        }
    }

    // MARK: - Input

    /// Runs a box full of input through the command layer and carries out what it asks.
    ///
    /// One switch, here, rather than half of it on the connection: `/server` points the
    /// *app* at a new host, and a connection cannot replace itself. Everything else is
    /// the connection's, and this hands it straight over.
    public func submit(_ text: String, from target: Target?) async {
        await submit(text, from: target, on: activeConnection)
    }

    /// The same, against a named connection rather than the selected one.
    ///
    /// **The window a line was typed in is not always the window the tree has selected.** A
    /// detached channel on one network with the main window pointed at another was sending
    /// to whichever network the *tree* was showing — the buffer views had a perfectly good
    /// connection in hand and threw it away. Prompt 9's context menus have the same shape of
    /// problem, so the connection became a parameter rather than a lookup.
    public func submit(
        _ text: String,
        from target: Target?,
        on connection: ConnectionViewModel?
    ) async {
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
            case .toAllChannels(let text, let isAction):
                await sendToAllChannels(text, isAction: isAction)
            case .ban(let channel, let subject, let isSet, let kickReason):
                await connection.ban(
                    channel: channel,
                    subject: subject,
                    isSet: isSet,
                    kickReason: kickReason,
                    from: target
                )
            case .clearScrollback(let everywhere):
                clearScrollback(everywhere: everywhere, from: target, on: connection)
            case .openQuery(let nick, let message):
                // Selected, unlike a query opened by an arriving message: this one was
                // asked for, and `/query bob` that did not take you to bob would be a
                // command with no visible effect.
                let buffer = await connection.openQuery(with: nick)
                selection = .query(connection: connection.id, nick: buffer.nick)
                guard let message else { break }
                await connection.send(
                    IRCMessage(verb: "PRIVMSG", parameters: [nick, message]),
                    from: .nick(buffer.nick)
                )
            case .connect(let host, let port, let tls, let password):
                await connect(
                    toHost: host,
                    port: port,
                    tls: tls,
                    password: password,
                    reportingInto: target
                )
            case .notify(let nick, let isRemoval):
                connection.showNotice(applyNotify(nick: nick, isRemoval: isRemoval), in: target)
            case .ignore(let subject, let levels, let duration, let isRemoval):
                connection.showNotice(
                    applyIgnore(
                        subject: subject,
                        levels: levels,
                        duration: duration,
                        isRemoval: isRemoval
                    ),
                    in: target
                )
            case .debug(let command):
                // The canvas is where `/debug window` sends output, so the command opens
                // it: being told the trace is now going somewhere you cannot see would be
                // a strange way to answer.
                let answer = debug.apply(command)
                if case .toCanvas = command { showSettingsAndDebug() }
                connection.showNotice(answer, in: target)
            case .channelList(let parameters):
                // Told before asked, in that order: on a large network the first 322 is
                // back before the next line of this function would have run.
                connection.channelDirectory.beginCollecting()
                showChannelList(on: connection)
                await connection.send(
                    IRCMessage(verb: "LIST", parameters: parameters),
                    from: target
                )
            }
        }
    }

    /// Somebody on the notify list arrived or left.
    ///
    /// **Its own toggle, not a case of `AlertTrigger`.** Prompt 13b's note asked for that to
    /// be decided rather than defaulted: `AlertTrigger` describes what a *buffer* did, and a
    /// person signing on is not a buffer doing anything.
    func announcePresence(nick: String, isOnline: Bool) {
        guard isOnline, settings.alertsOnNotify else { return }
        alerts.post(
            Alert(
                source: "Caravan",
                sender: nil,
                text: "\(nick) is online",
                item: nil
            )
        )
    }

    /// Starts the idle clock, and points it at every connected network.
    ///
    /// Away is per connection on the wire and one decision to the user, so this fans out.
    func startAwayClock() {
        away.setAway = { [weak self] reason in
            guard let self else { return }
            for connection in connections where connection.isConnected {
                Task { await connection.setAway(reason) }
            }
            guard reason == nil else { return }
            // Coming back is where the away log went — one line, counted from state that
            // already exists, rather than a second viewer over what prompt 12 already logs.
            guard let sentence = awaySummary().sentence else { return }
            for connection in connections where connection.isConnected {
                connection.showNotice(sentence, in: nil)
            }
        }
        away.start()
    }

    /// What happened while you were gone, from the activity states that already know.
    func awaySummary() -> AwaySummary {
        let waiting = allBuffers.filter { $0.activity > .none }
        // A conversation is read off the row's own identity rather than a flag: `BufferRef`
        // is a snapshot for the tree and the switcher, and giving it a second way to say
        // what kind of buffer it is would be a second thing to keep in step.
        func isConversation(_ ref: BufferRef) -> Bool {
            if case .query = ref.item { return true }
            return false
        }
        return AwaySummary(
            highlights: waiting.filter { $0.activity == .highlight && !isConversation($0) }.count,
            conversations: waiting.filter(isConversation).count,
            busyBuffers: waiting.filter { $0.activity == .message || $0.activity == .activity }
                .count
        )
    }

    /// `/notify`, answering in the window it was typed in.
    func applyNotify(nick: String?, isRemoval: Bool) -> String {
        guard let nick else {
            guard !notifyList.nicks.isEmpty else { return "The notify list is empty" }
            return "Notify list: " + notifyList.nicks.joined(separator: ", ")
        }
        if isRemoval {
            return notifyList.remove(nick)
                ? "No longer watching for \(nick)"
                : "\(nick) was not on the notify list"
        }
        return notifyList.add(nick)
            ? "Watching for \(nick)"
            : "\(nick) is already on the notify list"
    }

    /// Asks for notification permission and puts up whatever surfaces are switched on.
    ///
    /// Called once from `RootView`'s `.task` rather than from `init`: asking for permission
    /// is a system dialog, and a model built by a test has no business raising one. The
    /// authorisation call is itself a no-op outside an `.app`, which is belt and braces.
    public func startAlerts() {
        menuBarItem.onSelect = { [weak self] item in
            self?.selection = item
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        alerts.requestAuthorisation()
        refreshAttentionSurfaces()
        startAwayClock()
        // A list edited in Options has to reach every open connection, not only the next one.
        notifyList.didChange = { [weak self] in
            guard let self else { return }
            for connection in connections where connection.isConnected {
                Task { await connection.updateNotifyList(self.notifyList.nicks) }
            }
        }
    }

    /// Recomputes the Dock badge and the menu-bar item from the buffers themselves.
    ///
    /// **Derived, never counted.** A second counter incremented on a highlight and
    /// decremented on a read is a counter that drifts the first time a buffer is closed
    /// while unread. `allBuffers` already knows, and this is cheap enough to run on the two
    /// events that can change the answer.
    public func refreshAttentionSurfaces() {
        let waiting = allBuffers.filter { $0.activity > .none }
        let highlighted = waiting.filter { $0.activity == .highlight }
        // **The badge counts highlights only**, per §3: badges are additive for the
        // highlight case and a badge for every kind of activity is a wall of numbers.
        NSApplication.shared.dockTile.badgeLabel =
            highlighted.isEmpty ? nil : String(highlighted.count)
        menuBarItem.setVisible(settings.showsMenuBarItem)
        menuBarItem.update(
            count: highlighted.count,
            rows: waiting.map {
                MenuBarItem.Row(
                    title: $0.qualifiedName,
                    item: $0.item,
                    isHighlight: $0.activity == .highlight
                )
            }
        )
    }

    /// `/ignore`, in all four of its moods, answering in the window it was typed in.
    ///
    /// **The answer is a sentence, not a confirmation.** `/ignore -pn bob` replying "ok"
    /// tells you nothing about what you just did; replying "Ignoring bob!*@* — private
    /// messages and notices" is how you find out that `-n` was the flag you meant.
    func applyIgnore(
        subject: String?,
        levels: IgnoreLevel,
        duration: Int?,
        isRemoval: Bool
    ) -> String {
        guard let subject else { return ignoreListing() }
        let mask = IgnoreList.mask(for: subject)

        if isRemoval {
            return ignores.remove(mask: mask)
                ? "No longer ignoring \(mask)"
                : "\(mask) was not being ignored"
        }

        let expires = duration.map { Date().addingTimeInterval(TimeInterval($0)) }
        ignores.add(IgnoreEntry(mask: mask, levels: levels, expires: expires))
        let forHowLong = duration.map { " for \(Self.spelled(seconds: $0))" } ?? ""
        return "Ignoring \(mask)\(forHowLong) — \(levels.summary)"
    }

    /// What a bare `/ignore` prints.
    private func ignoreListing() -> String {
        ignores.sweep()
        guard !ignores.entries.isEmpty else { return "Nobody is being ignored" }
        let lines = ignores.entries.map { entry -> String in
            let lapses = entry.expires.map {
                " (until \($0.formatted(date: .omitted, time: .shortened)))"
            }
            return "  \(entry.mask) — \(entry.levels.summary)\(lapses ?? "")"
        }
        return (["Ignoring:"] + lines).joined(separator: "\n")
    }

    /// "10 minutes" rather than "600 seconds", which is what the person typing `-u600` meant.
    static func spelled(seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds) second\(seconds == 1 ? "" : "s")"
        case ..<3600: "\(seconds / 60) minute\(seconds / 60 == 1 ? "" : "s")"
        default: "\(seconds / 3600) hour\(seconds / 3600 == 1 ? "" : "s")"
        }
    }

    /// `/amsg` and `/ame`: **every channel on every connected network**.
    ///
    /// Across networks, not just this one — mIRC's behaviour, and the reading that makes
    /// the command worth having: "tell everyone I am going out" is not a per-network
    /// thought. Only channels we are actually *in*: a parted buffer still in the tree
    /// would produce a `PRIVMSG` the server answers with 404.
    ///
    /// Sent one channel at a time rather than as a comma list, so that flood protection
    /// and the local echo see them as the separate messages they are.
    private func sendToAllChannels(_ text: String, isAction: Bool) async {
        let body =
            isAction ? CTCPMessage(command: "ACTION", argument: text).wireForm : text
        for connection in connections where connection.isConnected {
            for buffer in connection.channels where buffer.isJoined {
                await connection.send(
                    IRCMessage(verb: "PRIVMSG", parameters: [buffer.name.raw, body]),
                    from: .channel(buffer.name)
                )
            }
        }
    }

    /// `/clear` and `/clearall`.
    ///
    /// Scrollback belongs to the view models, so this is the app's to do rather than
    /// anything the session could be asked for.
    private func clearScrollback(
        everywhere: Bool,
        from target: Target?,
        on connection: ConnectionViewModel
    ) {
        guard everywhere else {
            connection.log(for: target).clear()
            return
        }
        for connection in connections {
            for entry in connection.buffers { entry.buffer.log.clear() }
        }
        debug.clearCanvas()
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
            activeConnection?.showError(
                "/server has no nickname to use — set one in the Connect sheet first",
                in: target
            )
            return
        }
        await connect(using: settings)
    }

    /// Opens a network. **Adds, rather than replacing.**
    ///
    /// It used to replace, because there could only be one. Now that there can be several,
    /// "connect" means "open another network" — the same thing the Connect sheet and
    /// `/server` have always looked like they meant. A host and port already open is
    /// selected rather than opened twice, which is what stops a second `/server` on the
    /// same network producing two identical rows.
    @discardableResult
    public func connect(using settings: ConnectionSettings) async -> ConnectionViewModel? {
        settings.rememberAsLastUsed(in: config, credentials: credentials)
        // The ident is part of what makes two connections the same network: against a
        // bouncer without `bouncer-networks`, `alice/libera` and `alice/oftc` are the same
        // host and port and are emphatically not the same network.
        if let existing = connections.first(where: {
            $0.host == settings.host && $0.port == settings.port
                && $0.configuration.ident == settings.sessionConfiguration.ident
                && $0.bouncerNetworkID == nil
        }) {
            selection = .status(existing.id)
            if case .disconnected = existing.state { await existing.connect() }
            return existing
        }
        return await open(configuration: settings.sessionConfiguration, settings: settings)
    }

    /// Builds a connection, adds it to the tree, selects it and connects.
    ///
    /// The one place a `ConnectionViewModel` is created, so a bouncer-bound network is put
    /// together exactly as a direct one is — which is what makes "the UI must not care"
    /// true rather than merely intended.
    @discardableResult
    private func open(
        configuration: SessionConfiguration,
        settings: ConnectionSettings,
        name: String? = nil,
        selecting: Bool = true
    ) async -> ConnectionViewModel {
        let connection = ConnectionViewModel(
            configuration: configuration,
            trace: trace,
            settings: self.settings,
            credentials: credentials(for: settings),
            name: name
        )
        connection.bufferOrder = bufferOrder
        connection.urlCatcher = urlCatcher
        connection.chatLog = chatLog
        connection.ignores = ignores
        connection.highlights = highlights
        connection.alerts = alerts
        connection.isBufferOnScreen = { [weak self] buffer in
            self?.onScreenBuffers.contains { $0 === buffer } ?? false
        }
        connection.activityDidChange = { [weak self] in self?.refreshAttentionSurfaces() }
        connection.presenceDidChange = { [weak self] nick, isOnline in
            self?.announcePresence(nick: nick, isOnline: isOnline)
        }
        // Only the unbound connection can enumerate, so only it needs the hook.
        if configuration.bouncerNetworkID == nil {
            connection.bouncerNetworksDidChange = { [weak self] control in
                Task { await self?.reconcileBouncerNetworks(of: control) }
            }
        }
        // The buffer you are looking at never accumulates an activity state. The selection
        // is the app's, so the connection is told how to ask rather than given a copy that
        // could go stale.
        connection.isSelected = { [weak self] buffer in
            self?.onScreenBuffers.contains { $0 === buffer } ?? false
        }
        connections.append(connection)
        if selecting { selection = .status(connection.id) }
        await connection.connect()
        // **After `connect()`, which waits for registration.** `MONITOR` before the server
        // has welcomed us is a line the server is entitled to ignore, and an `ISON` poll
        // with nothing to poll is a timer doing nothing.
        await connection.updateNotifyList(notifyList.nicks)
        return connection
    }

    /// Closes a network and takes its row out of the tree.
    ///
    /// A bouncer's control connection takes its bound networks with it: they are reached
    /// *through* it, and leaving them behind would leave rows that cannot reconnect.
    public func close(_ connection: ConnectionViewModel) async {
        let dependents = connections.filter {
            $0.bouncerNetworkID != nil && $0.host == connection.host && $0.port == connection.port
                && $0.id != connection.id
        }
        for dependent in connection.bouncerNetworkID == nil ? dependents : [] {
            await dependent.disconnect()
            connections.removeAll { $0.id == dependent.id }
        }
        await connection.disconnect()
        connections.removeAll { $0.id == connection.id }
        if activeConnection == nil { selection = connections.first.map { .status($0.id) } }
    }

    // MARK: - The bouncer

    /// Opens a network row for every network the bouncer is holding, and closes the ones
    /// it has let go.
    ///
    /// **This is the whole of bouncer mode.** Each upstream network gets its own
    /// connection, bound with `BOUNCER BIND` during registration — which is what the
    /// extension requires, since binding after registration is refused — and each is built
    /// by the same `open` that a direct connection goes through. From here down nothing
    /// knows the difference.
    ///
    /// Driven off ``ConnectionViewModel/bouncerNetworks``, which is the whole list rather
    /// than a delta, so this reconciles rather than applying edits. Called whenever that
    /// list changes: once for `BOUNCER LISTNETWORKS`, and again per `BOUNCER NETWORK` under
    /// `soju.im/bouncer-networks-notify`.
    ///
    /// **Serialized per bouncer, and re-run if the list moved while it was working.**
    /// Opening a network suspends, and a `BOUNCER NETWORK` arriving during that suspension
    /// would otherwise be reconciled against a list that is already stale — with the
    /// visible symptom that a network removed while another was being opened comes back.
    func reconcileBouncerNetworks(of control: ConnectionViewModel) async {
        guard !reconcilingBouncers.contains(control.id) else {
            bouncersNeedingReconcile.insert(control.id)
            return
        }
        reconcilingBouncers.insert(control.id)
        defer { reconcilingBouncers.remove(control.id) }
        repeat {
            bouncersNeedingReconcile.remove(control.id)
            await applyBouncerNetworks(of: control)
        } while bouncersNeedingReconcile.contains(control.id)
    }

    /// Bouncers whose reconcile is in flight, and those that changed while it was.
    @ObservationIgnored private var reconcilingBouncers: Set<UUID> = []
    @ObservationIgnored private var bouncersNeedingReconcile: Set<UUID> = []

    private func applyBouncerNetworks(of control: ConnectionViewModel) async {
        let wanted = control.bouncerNetworks
        let existing = connections.filter {
            $0.bouncerNetworkID != nil && $0.host == control.host && $0.port == control.port
        }

        // Networks the bouncer has dropped. Closed rather than left disconnected: the row
        // is gone from the bouncer, so a row that could never reconnect would be a lie.
        for connection in existing
        where !wanted.contains(where: { $0.id == connection.bouncerNetworkID }) {
            await connection.disconnect()
            connections.removeAll { $0.id == connection.id }
        }

        for network in wanted {
            if let already = existing.first(where: { $0.bouncerNetworkID == network.id }) {
                already.rename(to: network.displayName)
                continue
            }
            var configuration = control.configuration
            configuration.bouncerNetworkID = network.id
            // Never steals the selection: networks appear as the bouncer names them, which
            // may be seconds after connecting and several at once. Yanking the user into
            // the last one to arrive would be its own small hostility.
            await open(
                configuration: configuration,
                settings: bouncerSettings(for: control),
                name: network.displayName,
                selecting: false
            )
        }
        if activeConnection == nil { selection = connections.first.map { .status($0.id) } }
    }

    /// The settings a bound connection is built with: the control connection's, since it is
    /// the same host, the same TLS decision and the same credentials.
    private func bouncerSettings(for control: ConnectionViewModel) -> ConnectionSettings {
        var settings = ConnectionSettings.lastUsed(from: config, credentials: credentials)
        settings.host = control.host
        settings.port = control.port
        settings.loadSecrets(from: credentials)
        return settings
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
        for connection in connections { connection.applySettings() }
        debug.applySettings()
    }

    // MARK: - Completion

    /// What Tab completes against in a given window.
    ///
    /// Assembled here because it is the one place that can see all three sources at once:
    /// the buffer's membership, the connection's open channels, and the command table.
    /// Nothing in it needs a round trip — completing against anything the server would
    /// have to be asked for is the line this stage does not cross.
    public func completionSources(
        in buffer: ChannelBuffer?,
        on connection: ConnectionViewModel?
    ) -> CompletionSources {
        // The nick list's own order, which is rank then casemapped alphabetical.
        completionSources(nicks: buffer?.members.map(\.nick.raw) ?? [], on: connection)
    }

    /// The same, for a window whose "membership" is the two people in it.
    ///
    /// The connection is the *window's*, not the tree's: completing a channel name in a
    /// detached window used to offer whichever network the tree had selected.
    public func completionSources(
        nicks: [String],
        on connection: ConnectionViewModel?
    ) -> CompletionSources {
        CompletionSources(
            nicks: nicks,
            // This network's channels only. With two open, offering the other one's would
            // complete to a channel this connection cannot join.
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
    func markUnread(leaving previous: SidebarItem?) {
        guard let previous, previous != selection else { return }
        let renderer = settings.renderer
        switch previous {
        case .status(let id):
            connection(id: id)?.log.markUnreadPosition(with: renderer.unreadRule())
        case .channel(let id, let name):
            connection(id: id)?.buffer(named: name)?.log
                .markUnreadPosition(with: renderer.unreadRule())
        case .query(let id, let nick):
            connection(id: id)?.query(named: nick)?.log
                .markUnreadPosition(with: renderer.unreadRule())
        case .settingsAndDebug, .dashboard, .channelList:
            // A canvas has no scrollback to mark. §10 draws the buffer/canvas line and
            // this is one of the places it pays for itself.
            break
        }
    }

    /// Disconnects the selected network, leaving its row in the tree.
    ///
    /// The toolbar's button, which acts on what you are looking at. Closing a network
    /// entirely is ``close(_:)``, from the tree's context menu.
    public func disconnect() async {
        await activeConnection?.disconnect()
    }

    /// Disconnects every network, for application shutdown.
    public func disconnectAll() async {
        for connection in connections { await connection.disconnect() }
    }
}
