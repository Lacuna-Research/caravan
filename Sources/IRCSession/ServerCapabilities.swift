import IRCProtocol

/// One `PREFIX` entry: a channel mode and the character that displays it.
public struct ChannelPrefix: Sendable, Equatable {
    /// The mode letter, e.g. `o`.
    public let mode: Character
    /// The character shown before a nick, e.g. `@`.
    public let prefix: Character

    public init(mode: Character, prefix: Character) {
        self.mode = mode
        self.prefix = prefix
    }
}

/// `CHANMODES`, in the four groups the token defines.
///
/// The groups are what tell a mode parser how many arguments a mode takes, which is why
/// they are kept apart rather than flattened into one set.
public struct ChannelModeGroups: Sendable, Equatable {
    /// Group A: list modes. Always take a parameter, e.g. `b`.
    public var lists: Set<Character>
    /// Group B: always take a parameter, e.g. `k`.
    public var alwaysArgument: Set<Character>
    /// Group C: take a parameter only when being set, e.g. `l`.
    public var argumentWhenSet: Set<Character>
    /// Group D: never take a parameter, e.g. `m`.
    public var noArgument: Set<Character>

    public init(
        lists: Set<Character> = [],
        alwaysArgument: Set<Character> = [],
        argumentWhenSet: Set<Character> = [],
        noArgument: Set<Character> = []
    ) {
        self.lists = lists
        self.alwaysArgument = alwaysArgument
        self.argumentWhenSet = argumentWhenSet
        self.noArgument = noArgument
    }
}

/// What the server said it supports, from `RPL_ISUPPORT` (005).
///
/// `rawTokens` is the source of truth and keeps everything, including tokens we have no
/// typed accessor for — a client that discards what it does not understand cannot show
/// the user what the server actually said, and stage 2 will want some of these before it
/// wants a parser for them. The typed properties are derived from it on every change,
/// so negation (`-TOKEN`) is just a removal followed by a refresh back to the default.
public struct ServerCapabilities: Sendable, Equatable {
    /// Defaults for everything a server does not mention. These are the values the
    /// protocol specifies when the token is absent, not guesses.
    public enum Default {
        public static let caseMapping = IRCCaseMapping.rfc1459
        public static let channelTypes: Set<Character> = ["#", "&"]
        public static let prefixes = [
            ChannelPrefix(mode: "o", prefix: "@"), ChannelPrefix(mode: "v", prefix: "+"),
        ]
        public static let nickLength = 9
        public static let channelLength = 200
    }

    /// Every token, keyed by its uppercased name. `nil` means the token was sent without
    /// a value, which is distinct from an empty value.
    public private(set) var rawTokens: [String: String?] = [:]

    // MARK: - Typed accessors

    /// Drives every nick and channel-name comparison downstream.
    public private(set) var caseMapping = Default.caseMapping

    /// Characters that introduce a channel name.
    public private(set) var channelTypes = Default.channelTypes

    /// Membership prefixes, highest rank first, in the order the server declared.
    public private(set) var prefixes = Default.prefixes

    public private(set) var channelModes = ChannelModeGroups()

    public private(set) var network: String?
    public private(set) var nickLength = Default.nickLength
    public private(set) var channelLength = Default.channelLength
    public private(set) var topicLength: Int?

    /// `MODES`: how many mode changes may go in one `MODE` command.
    public private(set) var maximumModesPerCommand: Int?

    /// `TARGMAX`: per-command target limits. A `nil` value means unlimited.
    public private(set) var targetMaximums: [String: Int?] = [:]

    /// `STATUSMSG`: prefixes usable as a message target, e.g. `@#channel`.
    public private(set) var statusMessagePrefixes: Set<Character> = []

    public private(set) var supportsMonitor = false
    /// `nil` with ``supportsMonitor`` true means no advertised limit.
    public private(set) var monitorLimit: Int?

    public init() {}

    // MARK: - Applying tokens

    /// Applies the tokens of one `RPL_ISUPPORT` line.
    public mutating func apply(tokens: [String]) {
        for token in tokens {
            applyWithoutRefreshing(token)
        }
        refreshDerivedValues()
    }

    /// The tokens of a 005 line: everything between our nick and the trailing prose.
    ///
    /// `RPL_ISUPPORT` is `<nick> <token>{,13} :are supported by this server`, so both
    /// ends are fixed. A token containing a space is dropped too, since that can only be
    /// prose from a server that formats the line differently.
    public static func tokens(inISUPPORT message: IRCMessage) -> [String] {
        guard message.parameters.count >= 3 else { return [] }
        return message.parameters.dropFirst().dropLast().filter { !$0.contains(" ") }
    }

    private mutating func applyWithoutRefreshing(_ token: String) {
        guard !token.isEmpty else { return }
        if token.hasPrefix("-") {
            rawTokens.removeValue(forKey: String(token.dropFirst()).uppercased())
            return
        }
        if let separator = token.firstIndex(of: "=") {
            let name = String(token[token.startIndex..<separator]).uppercased()
            rawTokens[name] = Self.unescape(String(token[token.index(after: separator)...]))
        } else {
            // `updateValue`, not a subscript assignment: `dictionary[key] = nil` removes
            // the key, and a valueless token has to be stored, not erased.
            rawTokens.updateValue(nil, forKey: token.uppercased())
        }
    }

    /// Undoes `ISUPPORT`'s `\xHH` escaping, which is how a value carries a space or a
    /// backslash. An incomplete or non-hex escape is left as written rather than
    /// swallowed — the raw value is more useful than a guess.
    static func unescape(_ value: String) -> String {
        guard value.contains("\\x") else { return value }
        var result = ""
        var rest = Substring(value)
        while let marker = rest.range(of: "\\x") {
            result += rest[rest.startIndex..<marker.lowerBound]
            let digits = rest[marker.upperBound...].prefix(2)
            if digits.count == 2, let code = UInt8(digits, radix: 16),
                let scalar = Unicode.Scalar(UInt32(code))
            {
                result.append(Character(scalar))
                rest = rest[rest.index(marker.upperBound, offsetBy: 2)...]
            } else {
                result += "\\x"
                rest = rest[marker.upperBound...]
            }
        }
        return result + rest
    }

    /// Recomputes every typed accessor from ``rawTokens``.
    ///
    /// Done on write rather than on read because `caseMapping` is consulted on every
    /// nick comparison in the app, and reparsing a string there would be absurd.
    private mutating func refreshDerivedValues() {
        caseMapping =
            value(of: "CASEMAPPING").flatMap { IRCCaseMapping(token: $0) }
            ?? Default.caseMapping
        channelTypes = value(of: "CHANTYPES").map { Set($0) } ?? Default.channelTypes
        prefixes = value(of: "PREFIX").map(Self.parsePrefix) ?? Default.prefixes
        channelModes = value(of: "CHANMODES").map(Self.parseChannelModes) ?? ChannelModeGroups()
        network = value(of: "NETWORK")
        nickLength = value(of: "NICKLEN").flatMap(Int.init) ?? Default.nickLength
        channelLength = value(of: "CHANNELLEN").flatMap(Int.init) ?? Default.channelLength
        topicLength = value(of: "TOPICLEN").flatMap(Int.init)
        maximumModesPerCommand = value(of: "MODES").flatMap(Int.init)
        targetMaximums = value(of: "TARGMAX").map(Self.parseTargetMaximums) ?? [:]
        statusMessagePrefixes = value(of: "STATUSMSG").map { Set($0) } ?? []
        supportsMonitor = rawTokens.keys.contains("MONITOR")
        monitorLimit = value(of: "MONITOR").flatMap(Int.init)
    }

    /// The value of a token, or `nil` when it is absent or was sent without one.
    private func value(of name: String) -> String? {
        rawTokens[name] ?? nil
    }

    /// `(ov)@+` -> `o` shows as `@`, `v` shows as `+`, in that rank order.
    static func parsePrefix(_ value: String) -> [ChannelPrefix] {
        guard value.hasPrefix("("), let close = value.firstIndex(of: ")") else { return [] }
        let modes = Array(value[value.index(after: value.startIndex)..<close])
        let symbols = Array(value[value.index(after: close)...])
        return zip(modes, symbols).map { ChannelPrefix(mode: $0, prefix: $1) }
    }

    /// `beI,k,l,imnpst` -> the four groups, in order. Missing groups stay empty.
    static func parseChannelModes(_ value: String) -> ChannelModeGroups {
        let groups = value.split(separator: ",", omittingEmptySubsequences: false).map { Set($0) }
        func group(_ index: Int) -> Set<Character> {
            index < groups.count ? groups[index] : []
        }
        return ChannelModeGroups(
            lists: group(0),
            alwaysArgument: group(1),
            argumentWhenSet: group(2),
            noArgument: group(3)
        )
    }

    /// `PRIVMSG:4,NOTICE:3,JOIN:` -> limits, where a missing number means unlimited.
    static func parseTargetMaximums(_ value: String) -> [String: Int?] {
        var maximums: [String: Int?] = [:]
        for entry in value.split(separator: ",") {
            let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let command = parts.first, !command.isEmpty else { continue }
            let limit = parts.count > 1 ? Int(parts[1]) : nil
            maximums[command.uppercased()] = limit
        }
        return maximums
    }

    // MARK: - Derived lookups

    /// The prefix character for a membership mode, e.g. `o` -> `@`.
    public func prefix(forMode mode: Character) -> Character? {
        prefixes.first { $0.mode == mode }?.prefix
    }

    /// The membership mode for a prefix character, e.g. `@` -> `o`.
    public func mode(forPrefix prefix: Character) -> Character? {
        prefixes.first { $0.prefix == prefix }?.mode
    }

    /// Rank of a prefix character, 0 being the highest. `nil` when it is not a prefix.
    ///
    /// Prompt 8 sorts nick lists by this rather than by a hardcoded `@%+`.
    public func rank(ofPrefix prefix: Character) -> Int? {
        prefixes.firstIndex { $0.prefix == prefix }
    }

    /// Whether `name` looks like a channel on this server.
    public func isChannelName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return channelTypes.contains(first)
    }
}
