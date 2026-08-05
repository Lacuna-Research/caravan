import IRCProtocol

/// One mode change from a `MODE` line or a 324: `+o alice`, `-m`, `+k hunter2`.
///
/// The parsed form exists because a mode string is not self-describing — `+kl` takes one
/// argument or two depending on `CHANMODES`, and `+o` takes one only because `PREFIX`
/// says so. Splitting is done once, here, rather than by every consumer.
///
/// The raw arguments are deliberately *not* carried alongside: two representations of one
/// thing invites them to disagree. Anything the split could not account for — a trailing
/// argument no mode claimed, on a malformed line — is still in the `.raw` event, which is
/// what that guarantee is for.
public struct ModeChange: Sendable, Hashable {
    /// `true` for `+`, `false` for `-`.
    public let isSet: Bool

    /// The mode letter, e.g. `o`.
    public let mode: Character

    /// The argument the mode consumed, when it takes one.
    public let argument: String?

    public init(isSet: Bool, mode: Character, argument: String? = nil) {
        self.isSet = isSet
        self.mode = mode
        self.argument = argument
    }

    /// `+o alice`, as it would appear on the wire.
    public var wireForm: String {
        let sign = isSet ? "+" : "-"
        return argument.map { "\(sign)\(mode) \($0)" } ?? "\(sign)\(mode)"
    }
}

/// Splits a mode string and its arguments into individual changes.
public enum ModeParser {
    /// Parses `parameters` as a mode string followed by its arguments.
    ///
    /// `isChannel` decides whether arguments are consumed at all: user modes
    /// (`MODE alice +i`) never take one, and treating them as if they might would eat the
    /// next parameter of a line that has none.
    ///
    /// A mode the server never declared is assumed to take no argument. That is the
    /// choice that fails smallest: guessing that an unknown mode *does* take one would
    /// swallow an argument belonging to the mode after it and mis-parse the rest of the
    /// line, where guessing it does not leaves one mode short of its argument and every
    /// other mode correct.
    public static func changes(
        in parameters: [String],
        isChannel: Bool,
        capabilities: ServerCapabilities
    ) -> [ModeChange] {
        guard let modeString = parameters.first else { return [] }
        var arguments = parameters.dropFirst()
        var isSet = true
        var changes: [ModeChange] = []

        for character in modeString {
            switch character {
            case "+":
                isSet = true
            case "-":
                isSet = false
            default:
                let wantsArgument =
                    isChannel
                    && takesArgument(character, isSet: isSet, capabilities: capabilities)
                let argument = wantsArgument ? arguments.popFirst() : nil
                changes.append(ModeChange(isSet: isSet, mode: character, argument: argument))
            }
        }
        return changes
    }

    /// Whether a channel mode carries an argument in this direction.
    ///
    /// `PREFIX` is checked first: membership modes always take a nick, and a server that
    /// also lists them in `CHANMODES` group A must not change that.
    static func takesArgument(
        _ mode: Character,
        isSet: Bool,
        capabilities: ServerCapabilities
    ) -> Bool {
        if capabilities.prefixes.contains(where: { $0.mode == mode }) { return true }
        let groups = capabilities.channelModes
        if groups.lists.contains(mode) { return true }
        if groups.alwaysArgument.contains(mode) { return true }
        if groups.argumentWhenSet.contains(mode) { return isSet }
        return false
    }
}
