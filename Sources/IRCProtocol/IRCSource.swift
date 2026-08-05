/// Where a message came from.
public enum IRCSource: Sendable, Hashable {
    /// A server name, e.g. `irc.example.com`.
    case server(String)

    /// A user, `nick[!user][@host]`. Either or both of user and host may be absent.
    case user(nick: String, user: String?, host: String?)

    /// Parses a source prefix, which the caller supplies without its leading `:`.
    ///
    /// A bare token is a server only when it looks like one — that is, when it contains
    /// a dot. `coolguy` is a nick; `irc.example.com` is a server. Nothing in the
    /// protocol marks the difference, so this is a heuristic, and it is the same one
    /// every other client uses.
    public init(prefix: String) {
        if let bang = prefix.firstIndex(of: "!") {
            let nick = String(prefix[prefix.startIndex..<bang])
            let rest = prefix[prefix.index(after: bang)...]
            if let at = rest.firstIndex(of: "@") {
                self = .user(
                    nick: nick,
                    user: String(rest[rest.startIndex..<at]),
                    host: String(rest[rest.index(after: at)...])
                )
            } else {
                self = .user(nick: nick, user: String(rest), host: nil)
            }
        } else if let at = prefix.firstIndex(of: "@") {
            self = .user(
                nick: String(prefix[prefix.startIndex..<at]),
                user: nil,
                host: String(prefix[prefix.index(after: at)...])
            )
        } else if prefix.contains(".") {
            self = .server(prefix)
        } else {
            self = .user(nick: prefix, user: nil, host: nil)
        }
    }

    /// The nickname, for a user source.
    public var nick: String? {
        if case .user(let nick, _, _) = self { return nick }
        return nil
    }

    public var user: String? {
        if case .user(_, let user, _) = self { return user }
        return nil
    }

    public var host: String? {
        if case .user(_, _, let host) = self { return host }
        return nil
    }

    /// The prefix as it appears on the wire, without the leading `:`.
    public var wireForm: String {
        switch self {
        case .server(let name):
            return name
        case .user(let nick, let user, let host):
            var result = nick
            if let user { result += "!\(user)" }
            if let host { result += "@\(host)" }
            return result
        }
    }
}
