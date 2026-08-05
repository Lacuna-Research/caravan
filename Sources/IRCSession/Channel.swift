import IRCProtocol

/// One person in a channel.
public struct Member: Sendable, Hashable {
    public let nick: IRCNick

    /// Known only when the server told us — `JOIN` carries a full source, a `NAMES` reply
    /// usually does not (`userhost-in-names` is stage 2's).
    public var user: String?
    public var host: String?

    /// Membership mode letters held, e.g. `o`, `v`. Mode letters rather than prefix
    /// characters, because `@` is only `o` by way of `PREFIX`.
    public var modes: Set<Character>

    public init(nick: IRCNick, user: String? = nil, host: String? = nil, modes: Set<Character> = [])
    {
        self.nick = nick
        self.user = user
        self.host = host
        self.modes = modes
    }
}

/// A channel topic, and the provenance a server reports for it.
public struct Topic: Sendable, Equatable {
    /// Empty means the channel has no topic — which is what 331 says, and what a `TOPIC`
    /// clearing one sends.
    public var text: String

    /// The nick 333 attributed it to, when the server sent one.
    public var setBy: String?

    /// Unix epoch seconds, as 333 reports it.
    ///
    /// Kept as the wire integer rather than a `Date`: this module has no Foundation
    /// dependency and formatting belongs to the layer that knows the user's locale. A
    /// topic changed while we are watching has no timestamp here at all — the session has
    /// no clock, and the buffer's own line already carries the time.
    public var setAt: Int?

    public init(text: String, setBy: String? = nil, setAt: Int? = nil) {
        self.text = text
        self.setBy = setBy
        self.setAt = setAt
    }

    public var isEmpty: Bool { text.isEmpty }
}

/// A channel as the session knows it: who is in it, what its topic is, and whether we are
/// currently a member.
///
/// Handed out as an immutable snapshot. The type owns its own membership transitions so
/// that the ordered nick list and the keyed one cannot drift apart — every mutation goes
/// through a method that maintains both.
///
/// **`isJoined` is not "does this exist".** A channel we were parted or kicked from keeps
/// its entry, and its buffer keeps its scrollback: membership never outlives its buffer,
/// but a buffer may outlive membership.
public struct Channel: Sendable, Equatable {
    public let name: IRCChannelName

    /// `nil` until the server says otherwise. Distinct from a topic that is set and empty,
    /// which is what 331 reports.
    public private(set) var topic: Topic?

    /// Channel modes without an argument, e.g. `n`, `t`.
    public private(set) var modes: Set<Character> = []

    /// Channel modes with an argument, e.g. `k` -> the key, `l` -> the limit.
    public private(set) var modeArguments: [Character: String] = [:]

    /// Whether we are in the channel right now.
    public var isJoined: Bool = false

    /// Members keyed by nick, folded under the server's casemapping.
    public private(set) var members: [IRCNick: Member] = [:]

    /// Members in nick-list order: `PREFIX` rank first, then casemapped alphabetical.
    ///
    /// Maintained incrementally rather than sorted on read. A netsplit is thousands of
    /// removals in a row, and re-sorting a two-thousand-member channel on each one is the
    /// difference between a hitch and a freeze.
    public private(set) var orderedMembers: [Member] = []

    /// The `PREFIX` table this channel's ordering is expressed in.
    ///
    /// Carried on the snapshot so a nick list can be sorted and drawn without reaching
    /// back into the session for capabilities it would have to `await`.
    public let prefixes: [ChannelPrefix]

    public let mapping: IRCCaseMapping

    public init(
        name: IRCChannelName,
        prefixes: [ChannelPrefix] = ServerCapabilities.Default.prefixes,
        mapping: IRCCaseMapping = .rfc1459
    ) {
        self.name = name
        self.prefixes = prefixes
        self.mapping = mapping
    }

    public var memberCount: Int { members.count }

    /// The highest-ranking prefix character a member holds, e.g. `@`.
    public func prefix(for member: Member) -> Character? {
        prefixes.first { member.modes.contains($0.mode) }?.prefix
    }

    /// The member's nick with its prefix, as a nick list and a message line show it.
    public func displayName(for member: Member) -> String {
        prefix(for: member).map { "\($0)\(member.nick.raw)" } ?? member.nick.raw
    }

    // MARK: - Membership

    mutating func addMember(_ member: Member) {
        if let existing = members[member.nick] {
            // A JOIN for someone already listed is a `NAMES` entry gaining its user@host,
            // not a second person. Merge rather than duplicating a row in the nick list.
            var merged = existing
            merged.user = member.user ?? existing.user
            merged.host = member.host ?? existing.host
            merged.modes.formUnion(member.modes)
            replaceMember(merged)
            return
        }
        members[member.nick] = member
        orderedMembers.insert(member, at: insertionIndex(for: member))
    }

    @discardableResult
    mutating func removeMember(_ nick: IRCNick) -> Member? {
        guard let member = members.removeValue(forKey: nick) else { return nil }
        if let index = orderedMembers.firstIndex(where: { $0.nick == nick }) {
            orderedMembers.remove(at: index)
        }
        return member
    }

    /// Renames a member, keeping the list ordered. Returns whether anyone was renamed.
    @discardableResult
    mutating func renameMember(from oldNick: IRCNick, to newNick: IRCNick) -> Bool {
        guard var member = removeMember(oldNick) else { return false }
        member = Member(nick: newNick, user: member.user, host: member.host, modes: member.modes)
        addMember(member)
        return true
    }

    public func contains(_ nick: IRCNick) -> Bool { members[nick] != nil }

    /// Replaces the whole membership, as the end of a `NAMES` burst does.
    mutating func replaceMembers(_ replacements: [Member]) {
        members = Dictionary(
            replacements.map { ($0.nick, $0) },
            uniquingKeysWith: { _, last in last }
        )
        orderedMembers = members.values.sorted(by: precedes)
    }

    mutating func clearMembers() {
        members.removeAll()
        orderedMembers.removeAll()
    }

    /// Re-sorts and re-keys everything under a new casemapping or `PREFIX` table.
    ///
    /// Needed because a reconnect resets `ISUPPORT`: keys folded under `ascii` do not
    /// match the same names folded under `rfc1459`, so a channel carried across would
    /// quietly stop matching itself.
    func remapped(mapping newMapping: IRCCaseMapping, prefixes newPrefixes: [ChannelPrefix])
        -> Channel
    {
        var channel = Channel(
            name: IRCChannelName(name.raw, mapping: newMapping),
            prefixes: newPrefixes,
            mapping: newMapping
        )
        channel.topic = topic
        channel.modes = modes
        channel.modeArguments = modeArguments
        channel.isJoined = isJoined
        channel.replaceMembers(
            orderedMembers.map {
                Member(
                    nick: IRCNick($0.nick.raw, mapping: newMapping),
                    user: $0.user,
                    host: $0.host,
                    modes: $0.modes
                )
            }
        )
        return channel
    }

    // MARK: - Topic and modes

    mutating func setTopic(_ text: String, setBy: String?) {
        // A new topic invalidates the old attribution: 333 for the previous one says
        // nothing about this one.
        topic = Topic(text: text, setBy: setBy, setAt: nil)
    }

    mutating func setTopicAuthor(_ nick: String, setAt: Int?) {
        guard topic != nil else {
            // 333 without a 332 happens; the channel has a topic we were not told.
            topic = Topic(text: "", setBy: nick, setAt: setAt)
            return
        }
        topic?.setBy = nick
        topic?.setAt = setAt
    }

    /// Applies one mode change, to the channel or to a member.
    mutating func apply(_ change: ModeChange) {
        if prefixes.contains(where: { $0.mode == change.mode }) {
            guard let argument = change.argument else { return }
            let nick = IRCNick(argument, mapping: mapping)
            guard var member = members[nick] else { return }
            if change.isSet {
                member.modes.insert(change.mode)
            } else {
                member.modes.remove(change.mode)
            }
            replaceMember(member)
            return
        }

        if change.isSet {
            if let argument = change.argument {
                modeArguments[change.mode] = argument
            } else {
                modes.insert(change.mode)
            }
        } else {
            modes.remove(change.mode)
            modeArguments.removeValue(forKey: change.mode)
        }
    }

    /// Replaces the whole mode set, as 324 does.
    mutating func setModes(_ changes: [ModeChange]) {
        modes.removeAll()
        modeArguments.removeAll()
        for change in changes where !prefixes.contains(where: { $0.mode == change.mode }) {
            apply(change)
        }
    }

    /// `+nt` plus any keyed modes, as a channel's mode line reads.
    public var modeDescription: String {
        let letters = (modes.sorted() + modeArguments.keys.sorted()).map(String.init).joined()
        guard !letters.isEmpty else { return "" }
        let arguments = modeArguments.keys.sorted().compactMap { modeArguments[$0] }
        return (["+" + letters] + arguments).joined(separator: " ")
    }

    // MARK: - Ordering

    /// A member whose modes changed keeps its identity but may change rank, so it is
    /// removed and reinserted rather than written in place.
    private mutating func replaceMember(_ member: Member) {
        members[member.nick] = member
        if let index = orderedMembers.firstIndex(where: { $0.nick == member.nick }) {
            orderedMembers.remove(at: index)
        }
        orderedMembers.insert(member, at: insertionIndex(for: member))
    }

    private func insertionIndex(for member: Member) -> Int {
        var low = 0
        var high = orderedMembers.count
        while low < high {
            let middle = (low + high) / 2
            if precedes(orderedMembers[middle], member) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// `PREFIX` rank as the server declared it, then casemapped alphabetical. Never a
    /// hardcoded `@%+`: a server is free to declare `(qaohv)~&@%+`, and half the networks
    /// that matter do.
    private func precedes(_ lhs: Member, _ rhs: Member) -> Bool {
        let lhsRank = rank(of: lhs)
        let rhsRank = rank(of: rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.nick.folded < rhs.nick.folded
    }

    private func rank(of member: Member) -> Int {
        prefixes.firstIndex { member.modes.contains($0.mode) } ?? prefixes.count
    }
}
