import IRCProtocol

/// Where a message was addressed: a channel, or a nickname.
///
/// Both halves compare under the server's casemapping, so this is safe as a dictionary
/// key — which is what prompt 8's per-window state will need it for.
public enum Target: Sendable, Hashable, CustomStringConvertible {
    case channel(IRCChannelName)
    case nick(IRCNick)

    /// Classifies a raw target string using the server's `CHANTYPES`.
    ///
    /// A `STATUSMSG` prefix is stripped first: `@#swift` addresses the operators of
    /// `#swift`, and without stripping it the leading `@` would make the whole thing
    /// look like a nickname. The distinction between `@#swift` and `#swift` is not lost
    /// — it is right there in the `.raw` event — but the *window* it belongs to is the
    /// channel either way.
    public init(_ raw: String, capabilities: ServerCapabilities) {
        var name = Substring(raw)
        while let first = name.first, capabilities.statusMessagePrefixes.contains(first) {
            name = name.dropFirst()
        }
        if let first = name.first, capabilities.channelTypes.contains(first) {
            self = .channel(IRCChannelName(String(name), mapping: capabilities.caseMapping))
        } else {
            self = .nick(IRCNick(raw, mapping: capabilities.caseMapping))
        }
    }

    /// The name as it was received.
    public var raw: String {
        switch self {
        case .channel(let channel): channel.raw
        case .nick(let nick): nick.raw
        }
    }

    public var isChannel: Bool {
        if case .channel = self { true } else { false }
    }

    /// The casemapping the name was folded under, which is the server's live one.
    public var mapping: IRCCaseMapping {
        switch self {
        case .channel(let channel): channel.mapping
        case .nick(let nick): nick.mapping
        }
    }

    public var description: String { raw }
}
