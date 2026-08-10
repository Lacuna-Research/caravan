import Foundation
import IRCProtocol

/// Who is talking faster than a person talks.
///
/// **This drops; the outbound limiter delays.** A message shown thirty seconds late is worse
/// than one not shown, so there is nothing to queue here — the answer to a flood is to stop
/// listening for a while, which is exactly `IgnoreEntry.expires` and therefore not a second
/// mechanism to learn.
///
/// **It counts messages from *people*, and that is what keeps `/list` out of it.** Numerics
/// are not counted — not by an exception, but because they are not messages — so the
/// thousands of a `LIST` reply, a large `NAMES` and every `MOTD` are outside this rather
/// than special-cased inside it.
public struct FloodDetector: Sendable {
    /// How many messages from one nick, inside ``window``, is not a person talking.
    ///
    /// **Twelve in five seconds, and the numbers came from the live run rather than from
    /// taste.** The first attempt was twenty in ten seconds, which turned out to be
    /// unreachable: Libera throttles a *sender*, and a scripted client trying to deliver
    /// twenty-four lines as fast as it could got fourteen through in five seconds before the
    /// server silenced it. A threshold no flood on the network can cross is a feature that
    /// cannot fire. Twelve in five is inside what the server permits and is still nothing a
    /// person types — two lines a second, sustained.
    ///
    /// In the source with the reasoning rather than in a settings pane: a threshold on a
    /// slider is a number to argue about and never a number anybody sets.
    public let limit: Int
    public let window: TimeInterval
    /// How long the automatic ignore lasts. Long enough to stop a flood, short enough that
    /// a mistake costs a minute.
    public let duration: TimeInterval

    /// When each nick last spoke, oldest first, bounded by ``window``.
    ///
    /// Keyed on the folded nick, so `Bob` and `bob` are one person on every server anybody
    /// uses — the same rule the ignore list and the roster follow.
    private var recent: [IRCNick: [Date]] = [:]

    public init(limit: Int = 12, window: TimeInterval = 5, duration: TimeInterval = 60) {
        self.limit = limit
        self.window = window
        self.duration = duration
    }

    /// Records one message and says whether that nick has just crossed the line.
    ///
    /// **`when` is the line's own timestamp, not the moment it arrived.** `server-time` is
    /// how `Alerts.shouldAlert` already tells history from news, and it is what makes a
    /// bouncer's replay harmless here: a hundred lines delivered in one second, stamped
    /// minutes apart, is a hundred messages over an hour and not a flood. No replay state is
    /// needed to know that.
    ///
    /// Returns `true` exactly once per flood — the crossing, not every message after it —
    /// because the caller's response is to add an ignore, and adding it fifty times would
    /// announce it fifty times.
    public mutating func record(nick: IRCNick, at when: Date) -> Bool {
        var stamps = recent[nick, default: []].filter { when.timeIntervalSince($0) < window }
        stamps.append(when)
        let tripped = stamps.count >= limit
        // Cleared on the crossing, so the next report is a *fresh* flood rather than the
        // tail of this one arriving after the ignore lapses.
        recent[nick] = tripped ? [] : stamps
        return tripped
    }

    /// Forgets a nick — used when an ignore is lifted, so the count starts again.
    public mutating func forget(nick: IRCNick) {
        recent[nick] = nil
    }
}
