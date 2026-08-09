import Foundation
import IRCSession
import Observation

/// The people you want to know about.
///
/// **A list of nicks and nothing else.** Not masks — `IgnoreList` matches
/// `nick!user@host` because an ignore is about a *person however they connect*, and a
/// notify is about a name being taken on this network. `MONITOR` and `ISON` both speak
/// nicks and neither takes a wildcard, so a mask here would be a promise the protocol
/// cannot keep.
///
/// **Global, like the ignore and highlight lists.** Whether bob is around is not a
/// per-network question to a user, even though it is answered per network on the wire.
///
/// Backed by `caravan.conf` as `notify.<n> = <nick>` — the shape prompt 13a settled, with
/// no second field, so the value is the whole record.
@MainActor
@Observable
public final class NotifyList {
    /// In the order they were added, which is the order they are written and shown.
    public private(set) var nicks: [String] = []

    @ObservationIgnored private let config: ConfigFile

    public static let keyPrefix = "notify."

    public init(config: ConfigFile = .shared) {
        self.config = config
        var loaded: [String] = []
        for key in config.keys(withPrefix: Self.keyPrefix).sorted(by: Self.byIndex) {
            guard Int(key.dropFirst(Self.keyPrefix.count)) != nil,
                let value = config.string(key)?.trimmingCharacters(in: .whitespaces),
                !value.isEmpty
            else { continue }
            loaded.append(value)
        }
        nicks = loaded
    }

    private static func byIndex(_ first: String, _ second: String) -> Bool {
        let left = Int(first.dropFirst(keyPrefix.count)) ?? Int.max
        let right = Int(second.dropFirst(keyPrefix.count)) ?? Int.max
        return left == right ? first < second : left < right
    }

    /// Called after the list changes, so every connection can re-issue its `MONITOR`.
    @ObservationIgnored public var didChange: (@MainActor () -> Void)?

    /// Adds a nick, or does nothing if it is already there.
    ///
    /// **Compared case-insensitively but stored as typed.** `Bob` and `bob` are one person
    /// on every server anybody uses, and the casemapping that decides it for certain is the
    /// *connection's* — which a global list does not have. Folding with `lowercased()` here
    /// is the honest approximation; the session folds properly when it matches.
    @discardableResult
    public func add(_ nick: String) -> Bool {
        let trimmed = nick.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !contains(trimmed) else { return false }
        nicks.append(trimmed)
        write()
        didChange?()
        return true
    }

    @discardableResult
    public func remove(_ nick: String) -> Bool {
        let before = nicks.count
        nicks.removeAll { $0.lowercased() == nick.lowercased() }
        guard nicks.count != before else { return false }
        write()
        didChange?()
        return true
    }

    public func contains(_ nick: String) -> Bool {
        nicks.contains { $0.lowercased() == nick.lowercased() }
    }

    private func write() {
        for key in config.keys(withPrefix: Self.keyPrefix) {
            config.set(nil, forKey: key)
        }
        for (index, nick) in nicks.enumerated() {
            config.set(nick, forKey: "\(Self.keyPrefix)\(index + 1)")
        }
    }
}
