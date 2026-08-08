import Foundation
import IRCProtocol
import Observation

/// One ignore: who, how much of them, and until when.
public struct IgnoreEntry: Identifiable, Hashable, Sendable {
    /// A `nick!user@host` wildcard mask. `*` and `?` are the only special characters,
    /// per ``IRCMask``.
    public var mask: String

    /// What it covers.
    public var levels: IgnoreLevel

    /// When it lapses, or `nil` for one that does not.
    ///
    /// Absolute rather than a remaining duration, so it survives a restart meaning the same
    /// thing. `/ignore -u600 bob` five minutes before you quit has five minutes left when
    /// you come back, not ten.
    public var expires: Date?

    /// The mask, which is what makes two entries the same ignore. Adding one that already
    /// exists replaces it rather than making a second.
    public var id: String { mask }

    public init(mask: String, levels: IgnoreLevel = .all, expires: Date? = nil) {
        self.mask = mask
        self.levels = levels
        self.expires = expires
    }

    func hasLapsed(at now: Date) -> Bool {
        guard let expires else { return false }
        return expires <= now
    }
}

/// Who you have stopped listening to.
///
/// **An ignore hides lines; it never changes state.** The invariant the whole feature rests
/// on. An ignored person still joins, still appears in the nick list, still holds their op
/// and still disappears when they quit — `IRCEvent.channelChanged(_:)` carries the roster
/// and is never suppressed. A client whose member list quietly disagrees with the server
/// because of a display filter is a worse bug than the noise it was hiding.
///
/// **Global rather than per network.** mIRC's `/ignore` takes an optional network; ours does
/// not, on the same reasoning §6 gives for colouring a nick by name alone — somebody who is
/// not worth reading is not worth reading wherever you reach them. The stored key leaves
/// room to add one.
///
/// Backed by `caravan.conf`, one key per entry: `ignore.1 = pcnt *!*@spam.example`. Prompt
/// 11's `<name>.<field>` shape cannot be used, because it parses on the first dot and every
/// useful mask has dots in it.
@MainActor
@Observable
public final class IgnoreList {
    /// In the order they were added, which is the order they are written and shown.
    public private(set) var entries: [IgnoreEntry] = []

    @ObservationIgnored private let config: ConfigFile

    /// The clock, injectable so a test of expiry is not a test of `sleep`.
    ///
    /// `@MainActor` rather than `@Sendable`: this type is main-actor bound, and a sendable
    /// closure cannot capture the mutable clock a test needs to advance.
    @ObservationIgnored public var now: @MainActor () -> Date = { Date() }

    public static let keyPrefix = "ignore."

    public init(config: ConfigFile = .shared) {
        self.config = config
        var loaded: [IgnoreEntry] = []
        for key in config.keys(withPrefix: Self.keyPrefix).sorted(by: Self.byIndex) {
            guard let value = config.string(key), let entry = Self.parse(value) else { continue }
            loaded.append(entry)
        }
        // A lapsed ignore is dropped on the way in rather than kept and filtered forever:
        // the file is the state, and a file full of expired entries is a file that lies.
        let current = Date()
        entries = loaded.filter { !$0.hasLapsed(at: current) }
        if entries.count != loaded.count { write() }
    }

    /// `ignore.2` before `ignore.10`, which a plain string sort gets backwards. The indices
    /// are ours to renumber, but the order a user typed them in is theirs.
    private static func byIndex(_ first: String, _ second: String) -> Bool {
        let left = Int(first.dropFirst(keyPrefix.count)) ?? Int.max
        let right = Int(second.dropFirst(keyPrefix.count)) ?? Int.max
        return left == right ? first < second : left < right
    }

    // MARK: - The list

    /// Adds an ignore, or replaces the one with the same mask.
    ///
    /// Replacing rather than appending is what makes `/ignore -n bob` after `/ignore -p bob`
    /// a correction instead of two entries whose combined effect nobody can predict.
    public func add(_ entry: IgnoreEntry) {
        entries.removeAll { $0.mask == entry.mask }
        entries.append(entry)
        write()
    }

    /// Removes an ignore by mask. `false` when there was none, so `/ignore -r` can say so
    /// rather than reporting a success it did not have.
    @discardableResult
    public func remove(mask: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.mask == mask }
        guard entries.count != before else { return false }
        write()
        return true
    }

    public func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        write()
    }

    /// Drops whatever has lapsed, and says whether anything did.
    ///
    /// Called before every match rather than on a timer: a timer that fires in a client
    /// nobody is looking at is a wakeup for nothing, and the only moment an expiry has to be
    /// correct is the moment somebody speaks.
    @discardableResult
    public func sweep() -> Bool {
        let current = now()
        let before = entries.count
        entries.removeAll { $0.hasLapsed(at: current) }
        guard entries.count != before else { return false }
        write()
        return true
    }

    // MARK: - Matching

    /// Which levels are ignored for this sender.
    ///
    /// Levels from every matching entry are combined: two masks that both catch somebody —
    /// `bob!*@*` for their notices and `*!*@their.host` for their CTCPs — mean both are
    /// ignored, which is the only reading that does not make the result depend on the order
    /// they were typed in.
    public func levels(for source: IRCSource, mapping: IRCCaseMapping = .rfc1459) -> IgnoreLevel {
        // **A server is never ignorable.** It has no nick, no user and no host to match on,
        // and a `*!*@*` entry taking out the MOTD would be a spectacular way to lose a
        // connection's own diagnostics.
        guard case .user = source else { return [] }
        sweep()
        let subject = Self.matchable(source)
        var level: IgnoreLevel = []
        for entry in entries
        where IRCMask.matches(mask: entry.mask, source: subject, mapping: mapping) {
            level.formUnion(entry.levels)
        }
        return level
    }

    /// `nick!user@host`, with `*` standing in for a part the server did not send.
    ///
    /// **Not ``IRCSource/wireForm``**, which renders a bare nick as `bob` — and `bob` does
    /// not match the mask `bob!*@*` that `/ignore bob` writes. Substituting `*` is safe in
    /// this direction only because glob matching treats the *subject* literally: a subject
    /// of `bob!*@*` still fails to match a mask of `bob!steve@host`, which is right, since
    /// we do not know that it is him.
    static func matchable(_ source: IRCSource) -> String {
        guard case .user(let nick, let user, let host) = source else { return source.wireForm }
        return "\(nick)!\(user ?? "*")@\(host ?? "*")"
    }

    /// The mask `/ignore <subject>` means.
    ///
    /// A bare nick becomes `nick!*@*` — deliberately *not* the `*!*@host` that
    /// ``ConnectionViewModel/banMask(for:in:)`` resolves from the roster. A ban wants to
    /// survive its target typing `/nick`; an ignore wants not to catch the forty other
    /// people behind one bouncer's host. Opposite defaults for identical-looking input, and
    /// both are right for what they do.
    public static func mask(for subject: String) -> String {
        guard !subject.contains("!"), !subject.contains("@") else { return subject }
        return "\(subject)!*@*"
    }

    // MARK: - The file

    /// `<levels> <mask> [<expiry as epoch seconds>]`.
    ///
    /// Three space-separated fields, because a mask cannot contain a space and neither can a
    /// run of letters — so the format needs no quoting and a person can edit it. The expiry
    /// is machine-written: nobody types an epoch, they type `-u600`.
    static func parse(_ value: String) -> IgnoreEntry? {
        let fields = value.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        let levels = fields[0] == "*" ? IgnoreLevel.all : IgnoreLevel(letters: fields[0])
        guard let levels, !levels.isEmpty else { return nil }
        let expiry =
            fields.count > 2 ? Double(fields[2]).map(Date.init(timeIntervalSince1970:)) : nil
        return IgnoreEntry(mask: String(fields[1]), levels: levels, expires: expiry)
    }

    static func format(_ entry: IgnoreEntry) -> String {
        var value = "\(entry.levels.letters) \(entry.mask)"
        if let expires = entry.expires {
            value += " \(Int(expires.timeIntervalSince1970))"
        }
        return value
    }

    /// Rewrites every `ignore.N`, renumbering from one.
    ///
    /// The whole family rather than a delta, and read back from the file rather than diffed
    /// against what we last wrote — the same rule `ChatSettings.colourOverrides` follows, and
    /// for the same reason: an `ignore.7` somebody added by hand is a key this owns and has
    /// to be able to clear.
    private func write() {
        for key in config.keys(withPrefix: Self.keyPrefix) {
            config.set(nil, forKey: key)
        }
        for (index, entry) in entries.enumerated() {
            config.set(Self.format(entry), forKey: "\(Self.keyPrefix)\(index + 1)")
        }
    }
}
