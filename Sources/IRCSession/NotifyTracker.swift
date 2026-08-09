import IRCProtocol

/// Who on the notify list is around, and the diffing that turns answers into changes.
///
/// **Three-valued, and that is the whole point.** A nick is online, offline, or *not yet
/// known* — and the third is not a synonym for the second. A list with no reply yet is not
/// a list of people who have left, and an `ISON` still in flight is not everybody signing
/// off. Collapsing the three into two is how a client comes to announce that all your
/// friends left the moment you connected.
///
/// Pure: no clock, no socket, no `MONITOR` string building. It is handed answers and says
/// what changed, which is what makes the awkward cases testable without a server.
public struct NotifyTracker: Sendable {
    /// The nicks being watched, folded under the server's casemapping.
    public private(set) var watched: [IRCNick] = []

    /// What is known. A nick absent from this is *unknown*, not offline.
    private var online: [IRCNick: Bool] = [:]

    /// Whether the baseline has been established for this connection.
    ///
    /// Reset by ``reset()`` on every disconnect: the answers from the last connection say
    /// nothing about this one, and treating them as current is how a reconnect announces
    /// changes that happened while nobody was listening.
    public private(set) var hasBaseline = false

    public init() {}

    /// Replaces the watch list, reporting what to add and remove on the wire.
    ///
    /// A nick dropped from the list loses its known state too — asking again later should
    /// produce a fresh answer rather than a stale one.
    public mutating func setWatched(
        _ nicks: [String],
        mapping: IRCCaseMapping
    ) -> (added: [String], removed: [String]) {
        let wanted = nicks.map { IRCNick($0, mapping: mapping) }
        let before = Set(watched)
        let after = Set(wanted)
        watched = wanted
        for nick in before.subtracting(after) { online[nick] = nil }
        return (
            added: wanted.filter { !before.contains($0) }.map(\.raw),
            removed: before.subtracting(after).map(\.raw)
        )
    }

    /// Applies one `MONITOR` 730/731, or one change learned any other way.
    ///
    /// Returns `true` when this was news. **A repeat is not news**: servers re-send 730 for
    /// somebody already online after a `MONITOR S`, and announcing it again would make the
    /// status window lie about something having happened.
    public mutating func apply(
        nick: String,
        isOnline: Bool,
        mapping: IRCCaseMapping
    ) -> Bool {
        let key = IRCNick(nick, mapping: mapping)
        // Not on the list: a server telling us about somebody we did not ask about is not
        // something to show. Adding them here would also make the list disagree with itself.
        guard watched.contains(key) else { return false }
        guard online[key] != isOnline else { return false }
        online[key] = isOnline
        return true
    }

    /// Applies an `ISON` reply, which names only who is online — so everything else on the
    /// list is offline *as of this answer*, and that is the one place the inference is safe.
    ///
    /// Returns the changes, and `nil` for each when this reply established the baseline.
    public mutating func applyISON(
        online replied: [String],
        mapping: IRCCaseMapping
    ) -> [(nick: String, isOnline: Bool)] {
        let present = Set(replied.map { IRCNick($0, mapping: mapping) })
        var changes: [(String, Bool)] = []
        for nick in watched {
            let isOnline = present.contains(nick)
            if online[nick] != isOnline {
                online[nick] = isOnline
                changes.append((nick.raw, isOnline))
            }
        }
        return changes.map { (nick: $0.0, isOnline: $0.1) }
    }

    /// Marks the baseline as taken, and reports it.
    ///
    /// Called once per connection, after the first answer: everything known then is the
    /// starting position rather than a set of things that just happened.
    public mutating func takeBaseline() -> (online: [String], offline: [String]) {
        hasBaseline = true
        return (
            online: watched.filter { online[$0] == true }.map(\.raw),
            offline: watched.filter { online[$0] == false }.map(\.raw)
        )
    }

    /// Whether every watched nick has an answer.
    ///
    /// **An exact terminator where the protocol gives none.** `MONITOR +` is answered with a
    /// 730 or a 731 for every target, so once all of them are known the first answer is
    /// complete — no waiting required. The grace period stays as a backstop for the cases
    /// this cannot see: a server that silently drops a name it considers invalid, or one
    /// that never replies at all.
    public var isComplete: Bool {
        !watched.isEmpty && watched.allSatisfy { online[$0] != nil }
    }

    /// Whether a nick is known to be online. `nil` for not yet known.
    public func isOnline(_ nick: String, mapping: IRCCaseMapping) -> Bool? {
        online[IRCNick(nick, mapping: mapping)]
    }

    /// Everything known, for a form that shows the list with its state.
    public var states: [(nick: String, isOnline: Bool?)] {
        watched.map { (nick: $0.raw, isOnline: online[$0]) }
    }

    /// Forgets everything learned, keeping the watch list. For a disconnect.
    public mutating func reset() {
        online.removeAll()
        hasBaseline = false
    }
}
