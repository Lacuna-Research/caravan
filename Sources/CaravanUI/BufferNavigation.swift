import Foundation
import IRCProtocol

/// One buffer as the navigation features see it: an identity, where it lives, and how
/// badly it wants your attention.
///
/// A value rather than a reference, so the quick-switcher's list and the MRU order can be
/// held, compared and diffed without pinning buffer objects alive.
public struct BufferRef: Identifiable, Hashable, Sendable {
    public let item: AppModel.SidebarItem
    public let connectionID: UUID
    /// The network's row in the tree — "Libera.Chat".
    public let networkName: String
    /// The buffer's own name: `#swift`, `bob`, or the network's name for a status window.
    public let name: String
    public let activity: BufferActivity
    /// Whether this row *is* its network's status window.
    public let isStatus: Bool

    public var id: AppModel.SidebarItem { item }

    /// `Libera.Chat/#swift` — always says which network, because `#music` on two networks
    /// are different rooms and any list that cannot say which is broken (§12).
    public var qualifiedName: String {
        isStatus ? networkName : "\(networkName)/\(name)"
    }
}

extension AppModel {
    // MARK: - The flat list

    /// Every buffer on every network, in the order the tree shows them.
    ///
    /// The thing prompt 4's and prompt 5's carry-forward notes both asked for. Four
    /// features read it: next-unread, next-highlight, the ⌘K switcher and the MRU order.
    public var allBuffers: [BufferRef] {
        connections.flatMap { connection in
            connection.buffers.map { entry in
                BufferRef(
                    item: entry.item,
                    connectionID: connection.id,
                    networkName: connection.displayName,
                    name: entry.buffer.displayName,
                    activity: entry.buffer.activity,
                    isStatus: entry.buffer === connection.status
                )
            }
        }
    }

    /// The buffer object a row names, or `nil` for a row that is not a buffer.
    public func buffer(for item: SidebarItem) -> (any ChatBuffer)? {
        switch item {
        case .status(let id):
            return connection(id: id)?.status
        case .channel(let id, let name):
            return connection(id: id)?.buffer(named: name)
        case .query(let id, let nick):
            return connection(id: id)?.query(named: nick)
        case .settingsAndDebug:
            // A canvas, not a buffer (§10). The distinction is the whole reason this
            // returns an optional.
            return nil
        }
    }

    // MARK: - Going to a buffer

    /// Selects a buffer and makes sure you can see it.
    ///
    /// **Auto-expands its network** (§9): jumping to a buffer hidden inside a collapsed
    /// group and leaving the group shut would be a jump to somewhere invisible. Every way
    /// of reaching a buffer that is not a click goes through here.
    public func reveal(_ item: SidebarItem) {
        if case .settingsAndDebug = item {
            selection = item
            return
        }
        if let connectionID = item.connectionID, let connection = connection(id: connectionID) {
            connection.isExpanded = true
        }
        selection = item
    }

    // MARK: - Next unread, next highlight

    /// The next buffer with anything new in it, after the current one, wrapping.
    ///
    /// **Two bindings, not one** (§9): on a busy network unread is noise and highlights
    /// are not, and a single key that lands you in `#firehose` on the way to a message
    /// addressed to you is the reason irssi grew two.
    public func selectNextUnread() {
        selectNext { $0.activity > .none }
    }

    /// The next buffer where somebody said something to you, after the current one.
    public func selectNextHighlight() {
        selectNext { $0.activity == .highlight }
    }

    /// Whether either binding has anywhere to go, for enabling the menu items.
    public var hasUnreadBuffer: Bool { allBuffers.contains { $0.activity > .none } }
    public var hasHighlightedBuffer: Bool { allBuffers.contains { $0.activity == .highlight } }

    /// Walks the flat list from just after the selection, wrapping once.
    ///
    /// Starting *after* the current buffer rather than at the top is what makes repeated
    /// presses sweep the tree instead of bouncing between the first two matches. The
    /// wrap is a rotation rather than a second pass, so a single matching buffer that is
    /// also the selected one is found rather than skipped.
    private func selectNext(matching predicate: (BufferRef) -> Bool) {
        let buffers = allBuffers
        guard !buffers.isEmpty else { return }
        let start = selection.flatMap { current in buffers.firstIndex { $0.item == current } }
        let rotation = start.map { $0 + 1 } ?? 0
        let order = (0..<buffers.count).map { buffers[($0 + rotation) % buffers.count] }
        guard let next = order.first(where: predicate) else { return }
        reveal(next.item)
    }

    // MARK: - Most recently used

    /// Ctrl+Tab, the **Windows Alt-Tab model** (§9): tap to toggle the last two, hold and
    /// keep tapping to walk further back. Not Chrome's positional order, which is the
    /// wrong model and widely disliked for exactly this reason.
    ///
    /// The subtlety that makes it work: while the modifier is held the MRU order is
    /// **frozen**. Committing each step would reshuffle the list under the walk, so the
    /// second tap would bring you back where you started and walking further back would be
    /// impossible. `endMRUCycle()` — driven by the modifier being released — is what
    /// commits.
    public func cycleMRU(backwards: Bool = false) {
        if mruCycle == nil {
            // Snapshot the order, dropping buffers that have since closed.
            let live = Set(allBuffers.map(\.item))
            var order = recentBuffers.filter { live.contains($0) }
            // Anything never visited goes on the end, so a fresh session can still walk.
            order += allBuffers.map(\.item).filter { !order.contains($0) }
            guard order.count > 1 else { return }
            mruCycle = MRUCycle(order: order, index: 0)
        }
        guard var cycle = mruCycle else { return }
        cycle.index = (cycle.index + (backwards ? -1 : 1) + cycle.order.count) % cycle.order.count
        mruCycle = cycle
        // Selecting during a cycle deliberately does not promote: see `noteVisited`.
        reveal(cycle.order[cycle.index])
    }

    /// The modifier came up. Commit wherever the walk ended.
    public func endMRUCycle() {
        guard mruCycle != nil else { return }
        mruCycle = nil
        if let selection { noteVisited(selection) }
    }

    /// Records a buffer as the most recently used, unless a cycle is in flight.
    func noteVisited(_ item: SidebarItem) {
        guard mruCycle == nil else { return }
        recentBuffers.removeAll { $0 == item }
        recentBuffers.insert(item, at: 0)
        // Bounded: this is a navigation aid, not a history. Thirty buffers is the scale
        // the acceptance run works at and twice that is already more than anyone walks.
        if recentBuffers.count > 64 { recentBuffers.removeLast() }
    }
}

/// A Ctrl+Tab walk in progress.
struct MRUCycle {
    /// The order as it was when the walk started, frozen for its duration.
    var order: [AppModel.SidebarItem]
    var index: Int
}

extension AppModel.SidebarItem {
    /// The network a row belongs to, or `nil` for the canvas.
    var connectionID: UUID? {
        switch self {
        case .status(let id), .channel(let id, _), .query(let id, _): id
        case .settingsAndDebug: nil
        }
    }
}
