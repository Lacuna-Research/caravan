/// A nickname compared under a server's casemapping.
///
/// Wrapping the string is what makes `[String: Member]` safe: under `rfc1459` the keys
/// `Foo[]` and `foo{}` are the same user, and a plain `String` key would silently
/// create two entries.
public struct IRCNick: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The nickname exactly as it was received, which is what gets displayed.
    public let raw: String

    public let mapping: IRCCaseMapping

    /// The comparison form. Computed once, since these are used as dictionary keys.
    public let folded: String

    public init(_ raw: String, mapping: IRCCaseMapping = .rfc1459) {
        self.raw = raw
        self.mapping = mapping
        self.folded = mapping.foldedCase(raw)
    }

    public var description: String { raw }

    /// Equality and hashing use the folded form, so display case is irrelevant.
    ///
    /// The mapping participates too: names folded under different mappings are not
    /// interchangeable, and comparing them would be a bug worth surfacing rather than
    /// papering over.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mapping == rhs.mapping && lhs.folded == rhs.folded
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(mapping)
        hasher.combine(folded)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.folded < rhs.folded
    }
}

/// A channel name compared under a server's casemapping.
public struct IRCChannelName: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let raw: String
    public let mapping: IRCCaseMapping
    public let folded: String

    public init(_ raw: String, mapping: IRCCaseMapping = .rfc1459) {
        self.raw = raw
        self.mapping = mapping
        self.folded = mapping.foldedCase(raw)
    }

    public var description: String { raw }

    /// The leading prefix character, if any. `CHANTYPES` decides which are valid; this
    /// only reports what is there.
    public var prefix: Character? { raw.first }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mapping == rhs.mapping && lhs.folded == rhs.folded
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(mapping)
        hasher.combine(folded)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.folded < rhs.folded
    }
}
