/// What an ignore covers, as mIRC's letters.
///
/// Pure and here rather than in the app for the same reason ``IRCMask`` is — whose own note
/// already says it exists "for bans and ignores". This is a letter table, tables are worth
/// testing exhaustively, and both the command parser and the window layer have to speak it.
///
/// **Five of the seven are mIRC's and mean what mIRC means**: `p`, `c`, `n`, `t` and `i`
/// suppress private messages, channel messages, notices, CTCPs and invitations.
///
/// **`k` is the odd one out and does not suppress anything.** It strips formatting from what
/// this person says rather than hiding them, which is what you want for somebody whose every
/// line is a different colour but who is otherwise worth reading.
///
/// **`m` is ours.** `PLAN.md` records mIRC's flag set as `-pcntikm` without recording what
/// `m` meant, and no other letter is free for the ignore people actually ask for: the noise
/// somebody makes without saying anything — joining, parting, quitting and changing nick,
/// over and over, from a client that cannot hold a connection. Defined here rather than left
/// out, and worth revisiting the moment somebody produces mIRC's own definition of the
/// letter; `BUILD-LOG.md` carries that as a decision.
public struct IgnoreLevel: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// `p` — private messages.
    public static let privateMessages = IgnoreLevel(rawValue: 1 << 0)
    /// `c` — messages in a channel.
    public static let channelMessages = IgnoreLevel(rawValue: 1 << 1)
    /// `n` — notices, in a channel or otherwise.
    public static let notices = IgnoreLevel(rawValue: 1 << 2)
    /// `t` — CTCP requests and replies.
    public static let ctcps = IgnoreLevel(rawValue: 1 << 3)
    /// `i` — invitations.
    public static let invites = IgnoreLevel(rawValue: 1 << 4)
    /// `k` — **strip formatting rather than hide the line.** See the type's note.
    public static let controlCodes = IgnoreLevel(rawValue: 1 << 5)
    /// `m` — joins, parts, quits and nick changes. See the type's note.
    public static let movement = IgnoreLevel(rawValue: 1 << 6)

    /// Everything, which is what a bare `/ignore bob` means.
    public static let all: IgnoreLevel = [
        .privateMessages, .channelMessages, .notices, .ctcps, .invites, .controlCodes,
        .movement,
    ]

    /// Every level that *hides* a line, which is all of them but ``controlCodes``.
    public static let hiding: IgnoreLevel = all.subtracting(.controlCodes)

    /// The letters, in the order `PLAN.md` lists them, so a written value is stable.
    ///
    /// Order matters for more than tidiness: the file is hand-edited and a diff that
    /// reordered `pcnt` into `ctnp` on every save would be noise nobody could read past.
    public static let letters: [(Character, IgnoreLevel)] = [
        ("p", .privateMessages),
        ("c", .channelMessages),
        ("n", .notices),
        ("t", .ctcps),
        ("i", .invites),
        ("k", .controlCodes),
        ("m", .movement),
    ]

    /// Parses a run of letters. `nil` for any letter that is not one of ours, rather than
    /// silently dropping it — `/ignore -pz bob` is a typo, and acting on the `p` while
    /// ignoring the `z` is how a user comes to believe a flag exists.
    public init?(letters text: some StringProtocol) {
        var level: IgnoreLevel = []
        for character in text {
            guard let match = Self.letters.first(where: { $0.0 == character }) else {
                return nil
            }
            level.insert(match.1)
        }
        self = level
    }

    /// The letters, in table order. `*` for everything, which is what the file carries and
    /// what reads best in a list — `pcntikm` says nothing that `*` does not.
    public var letters: String {
        guard self != .all else { return "*" }
        return String(Self.letters.filter { contains($0.1) }.map(\.0))
    }

    /// A phrase for a line the user reads: "private messages and notices".
    ///
    /// Spelled out rather than shown as letters, because `/ignore` printing `pn` back at
    /// somebody who typed `-pn` has told them nothing they did not just say.
    public var summary: String {
        guard self != .all else { return "everything" }
        guard !isEmpty else { return "nothing" }
        let names = Self.letters.filter { contains($0.1) }.map { Self.name(of: $0.1) }
        guard names.count > 1 else { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    private static func name(of level: IgnoreLevel) -> String {
        switch level {
        case .privateMessages: "private messages"
        case .channelMessages: "channel messages"
        case .notices: "notices"
        case .ctcps: "CTCPs"
        case .invites: "invitations"
        case .controlCodes: "formatting"
        case .movement: "joins and parts"
        default: "something"
        }
    }
}
