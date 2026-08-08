import Foundation
import IRCProtocol
import Observation

/// The order the user has dragged a network's buffers into (GUI-DESIGN-NOTES.md §12).
///
/// §12 settles ordering as "join order, with manual drag-to-reorder, persisted". So this
/// is a *preference list*, not the order itself: a buffer named here takes the position it
/// names, and a buffer that has never been dragged keeps arriving in join order at the
/// end. That is what makes joining a channel you have never reordered do the obvious thing
/// while leaving the ones you have arranged where you put them.
///
/// **Channels and conversations are ordered separately**, which preserves §12's
/// channels-before-queries rule through any amount of dragging. That rule exists to keep
/// channel positions stable as transient PMs come and go, and a drag that could interleave
/// them would give it away for nothing.
@MainActor
@Observable
public final class BufferOrder {
    @ObservationIgnored private let config: ConfigFile

    /// Network key to the names in the order they should appear.
    private var channelOrder: [String: [String]] = [:]
    private var queryOrder: [String: [String]] = [:]

    /// `order.irc.libera.chat:6697.channels = #swift,#vapor`.
    ///
    /// The network part is `ConnectionViewModel.networkKey`, the same identifier ⌘1–9
    /// bindings use — and it inherits the same caveat: it is `host:port` for want of a
    /// stable user-facing network name, and the server-list prompt migrates both together.
    static func key(network: String, section: Section) -> String {
        "order.\(network).\(section.rawValue)"
    }

    public enum Section: String {
        case channels
        case queries
    }

    /// Moves a network's remembered order onto a new name, in memory. See
    /// ``BufferBindings/renameNetwork(_:to:)`` — the file is not the only copy.
    func renameNetwork(_ old: String, to new: String) {
        if let channels = channelOrder.removeValue(forKey: old) { channelOrder[new] = channels }
        if let queries = queryOrder.removeValue(forKey: old) { queryOrder[new] = queries }
    }

    public init(config: ConfigFile) {
        self.config = config
    }

    /// The saved order for one section, loading it on first use.
    private func order(network: String, section: Section) -> [String] {
        let cached = section == .channels ? channelOrder[network] : queryOrder[network]
        if let cached { return cached }
        let loaded =
            config.string(Self.key(network: network, section: section))?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        if section == .channels {
            channelOrder[network] = loaded
        } else {
            queryOrder[network] = loaded
        }
        return loaded
    }

    /// Records the order a section is now in.
    public func save(_ names: [String], network: String, section: Section) {
        if section == .channels {
            channelOrder[network] = names
        } else {
            queryOrder[network] = names
        }
        config.set(
            names.isEmpty ? nil : names.joined(separator: ","),
            forKey: Self.key(network: network, section: section)
        )
    }

    /// Where a newly opened buffer belongs among the ones already there.
    ///
    /// A name the user has never dragged goes on the end — join order, which is the default
    /// §12 keeps. A name they *have* dragged goes back where they put it, which is the whole
    /// point of persisting: rejoining `#swift` after a reconnect must not send it to the
    /// bottom of a list you spent time arranging.
    public func insertionIndex(
        for name: String,
        among existing: [String],
        network: String,
        section: Section
    ) -> Int {
        let saved = order(network: network, section: section)
        guard let rank = saved.firstIndex(of: name) else { return existing.count }
        // The first buffer that should sit *after* this one: either it is ranked lower, or
        // it was never dragged at all and therefore belongs at the end.
        let index = existing.firstIndex { other in
            guard let otherRank = saved.firstIndex(of: other) else { return true }
            return otherRank > rank
        }
        return index ?? existing.count
    }
}

extension AppModel {
    /// Drag-to-reorder, from the tree. Moves the buffers and remembers where they went.
    public func moveChannels(
        in connection: ConnectionViewModel,
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        let names = connection.moveChannels(fromOffsets: source, toOffset: destination)
        bufferOrder.save(
            names,
            network: connection.networkKey,
            section: BufferOrder.Section.channels
        )
    }

    public func moveQueries(
        in connection: ConnectionViewModel,
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        let names = connection.moveQueries(fromOffsets: source, toOffset: destination)
        bufferOrder.save(
            names,
            network: connection.networkKey,
            section: BufferOrder.Section.queries
        )
    }
}
