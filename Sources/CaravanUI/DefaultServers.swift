import Foundation

/// The networks a fresh install starts with.
///
/// §13 always said the Dashboard holds "pre-populated entries to connect to, plus Add
/// Server". This is that list: the ten largest IRC networks by measured concurrent users,
/// in that order, so somebody who has just installed a client can connect to somewhere
/// real without first having to know a hostname.
///
/// **Every endpoint here was connected to before it was written down**, and that mattered:
/// of the ten hostnames the public rankings list, five did not work as given. `irc.ircnet.net`
/// and `open.ircnet.net` do not resolve at all; `irc.efnet.org` presents a self-signed
/// certificate; and Undernet and QuakeNet actively *refuse* 6697. A pre-populated entry that
/// does not connect is worse than no entry, so the list ships what answered.
///
/// **Two of them are cleartext, and the app says so out loud.** Undernet and QuakeNet offer
/// no TLS on their round-robins — they refuse the port, rather than timing out — so the
/// choice was between omitting two of the largest networks on the internet and shipping two
/// entries that are not encrypted. They ship, and the Dashboard marks them, because a
/// default the user cannot see the shape of is the thing actually worth avoiding.
///
/// The order and the counts are from netsplit.de's mid-2026 figures. Nobody should treat
/// this as maintained: it is a starting point, every entry is editable and deletable, and
/// the file it seeds is the user's from the moment it exists.
public enum DefaultServers {
    /// The list, largest first.
    ///
    /// Names are lower-case because ``NetworkName`` requires it — they key `binding.N` and
    /// `order.<network>.channels`, so two entries differing only in case would be one
    /// network wearing two hats.
    public static var entries: [ServerEntry] {
        [
            entry("libera", host: "irc.libera.chat"),
            entry("oftc", host: "irc.oftc.net"),
            // No TLS: the round-robin refuses 6697.
            entry("undernet", host: "irc.undernet.org", tls: false),
            // `irc.ircnet.net` and `open.ircnet.net` do not resolve; this one answers with a
            // certificate that verifies.
            entry("ircnet", host: "ircnet.hostsailor.com"),
            entry("hackint", host: "irc.hackint.org"),
            entry("rizon", host: "irc.rizon.net"),
            // Self-signed, network-wide. Trust-on-first-use handles it: the user is asked
            // once, which is the honest thing for a network that really is self-signed.
            entry("efnet", host: "irc.efnet.org"),
            entry("dalnet", host: "irc.dal.net"),
            // No TLS, as Undernet.
            entry("quakenet", host: "irc.quakenet.org", tls: false),
            entry("freenode", host: "irc.freenode.net"),
        ]
    }

    private static func entry(_ name: String, host: String, tls: Bool = true) -> ServerEntry {
        var entry = ServerEntry(name: name, host: host)
        entry.port = tls ? 6697 : 6667
        entry.useTLS = tls
        // **Nothing connects on startup and nothing is a favourite.** A client that dialled
        // ten networks the first time it opened would announce a stranger's arrival on ten
        // networks, which is not a thing to do to somebody who has just double-clicked an
        // app. The nick comes from the global setting, so these carry none.
        entry.connectsOnStartup = false
        return entry
    }
}
