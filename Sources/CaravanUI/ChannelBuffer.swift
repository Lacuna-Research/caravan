import IRCProtocol
import IRCSession
import Observation

/// One channel window: its scrollback, and the last state snapshot the session sent.
///
/// Holds no transition logic. Every membership change arrives as a whole ``Channel`` on
/// ``IRCEvent/channelChanged(_:)``, so the nick list here is a copy of the session's
/// answer rather than a second implementation of it — which is the only way the two can
/// be guaranteed to agree.
@MainActor
@Observable
public final class ChannelBuffer: Identifiable {
    public let name: IRCChannelName

    /// A controller per buffer, as prompt 7 already arranged: a channel window is a
    /// second scrollback, not a rework of the first.
    public let log = MessageLogController()

    /// This window's input box and command history. Both belong to the buffer rather
    /// than to the view, or switching away and back would lose the line being written and
    /// leave the history attached to the wrong window.
    public let input = InputState()

    /// How badly this buffer wants your attention (§3). Reset when you look at it.
    public var activity: BufferActivity = .none

    public private(set) var channel: Channel

    /// `nonisolated` because `Identifiable` is not: the identity is the immutable name,
    /// so reading it off the main actor is safe and SwiftUI's diffing needs it to be.
    public nonisolated var id: IRCChannelName { name }

    init(name: IRCChannelName) {
        self.name = name
        self.channel = Channel(name: name)
    }

    func update(_ channel: Channel) {
        self.channel = channel
    }

    /// The channel's ban, quiet, invite and except lists, by mode letter.
    ///
    /// Empty until asked for: a list is a `MODE #swift +b` round trip, and asking for four
    /// of them on every join would be four requests per channel that nobody looked at.
    public private(set) var listModes: [Character: [ListModeEntry]] = [:]

    /// Lists whose reply is still arriving, so the dialog can say "loading" rather than
    /// "empty" — the two look identical and mean opposite things.
    public private(set) var pendingListModes: Set<Character> = []

    /// Marks a list as requested, and clears whatever was there.
    ///
    /// Replaced rather than merged: the server sends the whole list every time, and a
    /// merge would keep entries that had been removed since.
    public func beginListMode(_ mode: Character) {
        pendingListModes.insert(mode)
        listModes[mode] = []
    }

    func recordListMode(_ mode: Character, entry: ListModeEntry) {
        if !pendingListModes.contains(mode) { beginListMode(mode) }
        listModes[mode, default: []].append(entry)
    }

    func finishListMode(_ mode: Character) {
        pendingListModes.remove(mode)
        if listModes[mode] == nil { listModes[mode] = [] }
    }

    /// Whether we are in the channel. Drives the greyed "not in here right now" state,
    /// which a parted, kicked or disconnected buffer all share.
    public var isJoined: Bool { channel.isJoined }

    public var members: [Member] { channel.orderedMembers }

    public var memberCount: Int { channel.memberCount }

    /// The topic, or `nil` when the channel has none to show.
    public var topicText: String? {
        guard let topic = channel.topic, !topic.isEmpty else { return nil }
        return topic.text
    }

    /// Whether the given nick holds a prefix here, and so is likely to be allowed to set
    /// modes and kick people.
    ///
    /// **A guess, and deliberately a permissive one.** `PREFIX` says which prefixes a
    /// network has but not which of them may do what, and half-op and owner both can on the
    /// networks that have them — so this greys items out rather than refusing anything the
    /// server might have allowed.
    ///
    /// On the buffer since prompt 9, where the modes sheet and the two context menus all
    /// need the same answer. It used to be private to `ChannelModesSheet` *and* asked about
    /// `activeConnection`, which is the tree's selection rather than this window's network.
    public func canSetModes(as nick: String?) -> Bool {
        guard let nick else { return false }
        let key = IRCNick(nick, mapping: name.mapping)
        guard let member = channel.members[key] else { return false }
        return channel.prefix(for: member) != nil
    }
}
