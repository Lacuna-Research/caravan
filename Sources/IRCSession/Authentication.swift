/// How to prove who we are to a network.
///
/// One choice per connection rather than a list to try in turn. A client that quietly
/// walks down a list of mechanisms is a client that quietly authenticates with the weakest
/// one it can, and the user cannot see which.
///
/// **Every value here is a live credential.** They reach the wire and nothing else:
/// `TraceBuffer` redacts `AUTHENTICATE` and NickServ `IDENTIFY` on insert, nothing in this
/// module logs them, and their durable home is the macOS Keychain — never `caravan.conf`.
public enum AuthenticationMethod: Sendable, Equatable {
    case none

    /// SASL, with the mechanism named rather than chosen for us.
    ///
    /// Falls back to ``nickServ(account:password:)`` when the server offers no `sasl`
    /// capability at all and there is a password to identify with. That is a fallback for
    /// a server that cannot do SASL, not for credentials the server *rejected* — a
    /// rejection ends the attempt, because retrying a wrong password by another route is
    /// how an account gets locked.
    case sasl(mechanism: SASLMechanism, account: String, password: String)

    /// `PRIVMSG NickServ :IDENTIFY <account> <password>` once registration completes.
    ///
    /// Strictly worse than SASL and offered because a great many servers still have
    /// nothing else: the password crosses a registered but unauthenticated connection, and
    /// anything that arrives before it — an autojoin, an invite — happens as a stranger.
    case nickServ(account: String, password: String)

    /// The account name, for a status line. Empty when there is nothing to say.
    public var account: String {
        switch self {
        case .none: ""
        case .sasl(_, let account, _), .nickServ(let account, _): account
        }
    }

    /// The credentials to fall back to when the server cannot do SASL, or `nil` when
    /// there is nothing to fall back to.
    var nickServFallback: (account: String, password: String)? {
        guard case .sasl(let mechanism, let account, let password) = self else { return nil }
        // `EXTERNAL` has no password by construction, so there is nothing to identify with.
        guard mechanism.needsPassword, !account.isEmpty, !password.isEmpty else { return nil }
        return (account, password)
    }
}
