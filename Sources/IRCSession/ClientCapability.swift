import IRCProtocol

/// The IRCv3 capabilities this client asks a server for.
///
/// A capability earns a place here by having a consumer. `multi-prefix` changes what
/// ``ChannelRoster`` does with a `NAMES` reply, `echo-message` changes who draws your own
/// line, `server-time` changes what a timestamp means. Asking for one that nothing reads
/// would be a promise to the server that the client does not keep.
///
/// The one exception is documented where it is made: ``labeledResponse`` is negotiated
/// without being exercised, because it is inert until something sends a label.
public enum ClientCapability: String, Sendable, Hashable, CaseIterable {
    /// Lets the server announce capabilities appearing and disappearing mid-session.
    case capNotify = "cap-notify"
    /// `NAMES` lists every prefix a member holds, not just the highest.
    case multiPrefix = "multi-prefix"
    /// `AWAY` for anyone sharing a channel with us.
    case awayNotify = "away-notify"
    /// `ACCOUNT` when someone logs in or out of services.
    case accountNotify = "account-notify"
    /// `JOIN` carries the joiner's account and real name.
    case extendedJoin = "extended-join"
    /// `NAMES` entries are full `nick!user@host` sources.
    case userhostInNames = "userhost-in-names"
    /// A `time` tag saying when a line was *said*, which is not when it arrived.
    case serverTime = "server-time"
    /// Tags on messages that would otherwise carry none.
    case messageTags = "message-tags"
    /// The server echoes our own messages back, so it can draw them instead of us.
    case echoMessage = "echo-message"
    /// Groups related lines under a reference, which `chathistory` replay needs.
    case batch = "batch"
    /// `CHGHOST` when someone's user@host changes without a reconnect.
    case chghost = "chghost"
    /// `INVITE` for invitations we can see but did not send or receive.
    case inviteNotify = "invite-notify"
    /// `SETNAME` when someone changes their real name.
    case setname = "setname"
    /// `FAIL`/`WARN`/`NOTE` instead of an untyped numeric.
    case standardReplies = "standard-replies"
    /// Correlates a reply with the command that caused it.
    ///
    /// **Negotiated but not yet exercised.** It is inert without an outbound `label` tag,
    /// and the two things that want one — `chathistory` in prompt 4 and command replies in
    /// prompt 8 — do not exist yet. Asking now costs one token and means the capability is
    /// already in hand when they land; `BUILD-LOG.md` records the choice.
    case labeledResponse = "labeled-response"
    /// Authentication, which rides on the same negotiation.
    case sasl = "sasl"

    /// soju's bouncer extension: enumerate the upstream networks, and bind to one.
    case bouncerNetworks = "soju.im/bouncer-networks"
    /// The same, plus `BOUNCER NETWORK` when a network is added, changed or removed.
    case bouncerNetworksNotify = "soju.im/bouncer-networks-notify"
    /// Backfill what was said while we were detached.
    case chatHistory = "draft/chathistory"
}

/// What the server offers and what it has agreed to, for one connection.
///
/// Reset per attempt, like ``ServerCapabilities``: a capability is a property of the
/// connection, not of the client.
public struct NegotiatedCapabilities: Sendable, Equatable {
    /// Every capability the server advertised, with the value from a `name=value` token.
    ///
    /// The value is `""` for a token sent without one — the distinction has no consumer,
    /// unlike `ISUPPORT`, where an absent value and an empty one mean different things.
    public private(set) var available: [String: String] = [:]

    /// Every capability the server has acknowledged.
    public private(set) var enabled: Set<String> = []

    public init() {}

    // MARK: - Reading

    public func isEnabled(_ capability: ClientCapability) -> Bool {
        enabled.contains(capability.rawValue)
    }

    public func isAvailable(_ capability: ClientCapability) -> Bool {
        available[capability.rawValue] != nil
    }

    /// Enabled capabilities in a stable order, for a line the user reads.
    public var enabledNames: [String] { enabled.sorted() }

    /// The SASL mechanisms the server named, uppercased.
    ///
    /// A server that offers bare `sasl` without a mechanism list is the pre-3.2 form and
    /// means `PLAIN` — which is what every such server actually supports, and guessing
    /// wrong costs one rejected `AUTHENTICATE` rather than a failed connection.
    public var saslMechanisms: [String] {
        guard let value = available[ClientCapability.sasl.rawValue] else { return [] }
        guard !value.isEmpty else { return ["PLAIN"] }
        return value.split(separator: ",").map { $0.uppercased() }
    }

    // MARK: - Writing

    mutating func advertise(_ tokens: [CapabilityCommand.Token]) {
        for token in tokens {
            available[token.name] = token.value ?? ""
        }
    }

    mutating func withdraw(_ tokens: [CapabilityCommand.Token]) {
        for token in tokens {
            available.removeValue(forKey: token.name)
            enabled.remove(token.name)
        }
    }

    /// Applies an `ACK`, which may both enable and — with a `-` prefix — disable.
    mutating func acknowledge(_ tokens: [CapabilityCommand.Token]) {
        for token in tokens {
            if token.isDisabled {
                enabled.remove(token.name)
            } else {
                enabled.insert(token.name)
            }
        }
    }

    /// Replaces the enabled set, as a `CAP LIST` reply reports it.
    mutating func replaceEnabled(_ tokens: [CapabilityCommand.Token]) {
        enabled = Set(tokens.filter { !$0.isDisabled }.map(\.name))
    }
}

/// One `CAP` line, parsed.
///
/// `CAP <client> <subcommand> [*] [:<capabilities>]`, where the `*` means more lines of
/// the same subcommand follow. Parsed here rather than in the session so the awkward
/// shapes — a multiline `LS`, a `-cap` inside an `ACK`, a `name=value` token — are
/// testable without a socket.
public struct CapabilityCommand: Sendable, Equatable {
    public enum Subcommand: String, Sendable, Equatable {
        case ls = "LS"
        case list = "LIST"
        case ack = "ACK"
        case nak = "NAK"
        case new = "NEW"
        case del = "DEL"
    }

    /// One capability name, with whatever the token carried alongside it.
    public struct Token: Sendable, Equatable {
        public let name: String
        /// The right-hand side of `name=value`, or `nil` when there was no `=`.
        public let value: String?
        /// A leading `-`, which an `ACK` uses to confirm a capability being turned off.
        public let isDisabled: Bool

        public init(name: String, value: String? = nil, isDisabled: Bool = false) {
            self.name = name
            self.value = value
            self.isDisabled = isDisabled
        }
    }

    public let subcommand: Subcommand
    /// Whether another line of the same subcommand follows.
    public let isContinued: Bool
    public let tokens: [Token]

    /// Parses a `CAP` message, or returns `nil` for anything that is not one.
    public init?(message: IRCMessage) {
        guard message.command.isVerb("CAP"), message.parameters.count >= 2 else { return nil }
        // Parameter 0 is our nick, or `*` before registration finishes. Either way it is
        // not something to act on.
        guard let subcommand = Subcommand(rawValue: message.parameters[1].uppercased()) else {
            return nil
        }
        self.subcommand = subcommand

        var rest = Array(message.parameters.dropFirst(2))
        let isContinued = rest.first == "*"
        if isContinued { rest.removeFirst() }
        self.isContinued = isContinued

        self.tokens = Self.tokens(in: rest.last ?? "")
    }

    static func tokens(in list: String) -> [Token] {
        list.split(separator: " ").map { field in
            var name = Substring(field)
            let isDisabled = name.hasPrefix("-")
            if isDisabled { name = name.dropFirst() }
            guard let separator = name.firstIndex(of: "=") else {
                return Token(name: String(name), value: nil, isDisabled: isDisabled)
            }
            return Token(
                name: String(name[name.startIndex..<separator]),
                value: String(name[name.index(after: separator)...]),
                isDisabled: isDisabled
            )
        }
    }
}
