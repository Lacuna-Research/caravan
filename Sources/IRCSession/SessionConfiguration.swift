import IRCTransport

/// Everything needed to reach a server and register on it.
public struct SessionConfiguration: Sendable {
    public var host: String
    public var port: UInt16
    public var tls: TLSMode

    public var nick: String
    /// Tried first when the nick is taken, before falling back to appending `_`.
    public var altNick: String?
    /// The `<user>` of `USER`. Against a bouncer this is where `<user>/<network>` goes.
    public var ident: String
    public var realName: String

    /// Server password, sent as `PASS` before `NICK`.
    ///
    /// A live credential. It reaches the wire and nowhere else: `TraceBuffer` redacts
    /// `PASS` on insert, and nothing here is ever logged. Its durable home is the macOS
    /// Keychain — `CaravanUI.Keychain` — and never `caravan.conf`.
    public var password: String?

    /// How to prove who we are: SASL, NickServ, or neither. Also a live credential.
    public var authentication: AuthenticationMethod

    /// What a CTCP `VERSION` request is answered with.
    ///
    /// Configured rather than hardcoded because this module has no bundle to read a
    /// version out of, and a client that reports "Caravan" with no version is no use to
    /// whoever is asking why it misbehaves. The app fills it in from `Info.plist`.
    public var clientVersion: String

    /// How many lines to ask `draft/chathistory` for when a channel opens.
    ///
    /// Zero turns backfill off. The default is a screenful and a bit: enough that
    /// rejoining a channel lands you in the middle of the conversation rather than at a
    /// blank window, and few enough that a slow bouncer is not asked for a novel per
    /// channel on every reconnect.
    public var chatHistoryLimit: Int

    /// The bouncer network to `BOUNCER BIND` to during registration, if any.
    ///
    /// This is what makes one connection a *network* rather than the bouncer itself.
    /// `nil` means an ordinary connection — either a direct one to an ircd, or the
    /// unbound control connection to a bouncer, which is the only one that may enumerate
    /// networks and the only place `BouncerServ` can be reached.
    public var bouncerNetworkID: String?

    /// How long the whole of connecting *and* registering may take.
    ///
    /// One deadline for both because both fail the same way, and neither has a timeout
    /// anywhere below this layer. An unroutable address leaves `NWConnection` in
    /// `.connecting` for as long as anyone cares to watch, and a server that accepts TCP
    /// but never sends 001 is just as stuck. (A *refused* connection does fail promptly
    /// on its own — measured, and recorded in the build log.)
    public var connectTimeout: Duration

    /// Silence tolerated before we send our own `PING`.
    public var idleInterval: Duration
    /// How long that `PING` may go unanswered before the connection is treated as dead.
    public var idleResponseTimeout: Duration

    public var backoff: BackoffPolicy

    public init(
        host: String,
        port: UInt16,
        tls: TLSMode = .enabled(.system),
        nick: String,
        altNick: String? = nil,
        ident: String? = nil,
        realName: String? = nil,
        password: String? = nil,
        authentication: AuthenticationMethod = .none,
        clientVersion: String = "Caravan (macOS)",
        chatHistoryLimit: Int = 50,
        bouncerNetworkID: String? = nil,
        connectTimeout: Duration = .seconds(30),
        idleInterval: Duration = .seconds(120),
        idleResponseTimeout: Duration = .seconds(60),
        backoff: BackoffPolicy = BackoffPolicy()
    ) {
        self.host = host
        self.port = port
        self.tls = tls
        self.nick = nick
        self.altNick = altNick
        self.ident = ident ?? nick
        self.realName = realName ?? nick
        self.password = password
        self.authentication = authentication
        self.clientVersion = clientVersion
        self.chatHistoryLimit = chatHistoryLimit
        self.bouncerNetworkID = bouncerNetworkID
        self.connectTimeout = connectTimeout
        self.idleInterval = idleInterval
        self.idleResponseTimeout = idleResponseTimeout
        self.backoff = backoff
    }
}
