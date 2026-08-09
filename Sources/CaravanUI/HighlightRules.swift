import Foundation
import Observation

/// One thing that makes a line worth your attention.
public struct HighlightPattern: Identifiable, Hashable, Sendable {
    /// How the text is matched.
    public enum Kind: String, Sendable, Hashable, CaseIterable, Identifiable {
        /// A word or phrase, matched on boundaries and without regard to case.
        case word
        /// An `NSRegularExpression`, case-insensitive.
        case regex

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .word: "Word"
            case .regex: "Pattern"
            }
        }
    }

    public var kind: Kind
    public var text: String

    /// Kind and text together: `word:build failed` and `regex:build failed` are two rules,
    /// and adding the same one twice replaces rather than duplicates.
    public var id: String { "\(kind.rawValue):\(text)" }

    public init(kind: Kind = .word, text: String) {
        self.kind = kind
        self.text = text
    }

    /// Whether this pattern compiles, for a form that has to say so before it is saved.
    public var isValid: Bool {
        guard !text.isEmpty else { return false }
        guard kind == .regex else { return true }
        return (try? NSRegularExpression(pattern: text, options: [.caseInsensitive])) != nil
    }
}

/// What makes a line a highlight.
///
/// **This replaces `BufferActivity.mentions(_:in:)` rather than sitting beside it.** Prompt
/// 6 left exactly one rule — your own nick, matched as a word — because the four activity
/// states need at least one to mean anything. It is now the first of three, and it is still
/// the one that is on by default.
///
/// **Compiled once, on load.** A regular expression is expensive to build and this runs per
/// line of every channel; a user with ten patterns and a busy network would otherwise pay
/// for ten compilations a message.
///
/// **A pattern that will not compile costs the pattern, not the launch.** These arrive from
/// a text field and from a hand-edited file. The bad ones are collected in ``rejected`` so
/// the form can say which, and everything else keeps working.
@MainActor
@Observable
public final class HighlightRules {
    /// Whether your own nickname highlights. On, and the reason it is a toggle at all is
    /// somebody whose nick is a common word.
    public var matchesOwnNick: Bool {
        didSet { config.set(matchesOwnNick, forKey: Key.ownNick) }
    }

    /// Every pattern the user has, valid or not, in the order they were added.
    ///
    /// **One list, not two.** A broken pattern is still the user's — it has to be listable,
    /// removable and writable back to the file — so it lives here beside the others and is
    /// merely absent from ``compiled``. Two arrays meant a rejected pattern that `remove`
    /// could not reach and a write order that depended on which array it had landed in.
    public private(set) var patterns: [HighlightPattern] = []

    /// The ones that would not compile. Shown by the form; the alternative is a rule that
    /// silently never matches and a user who thinks it does.
    public var rejected: [HighlightPattern] {
        patterns.filter { $0.kind == .regex && compiled[$0.id] == nil }
    }

    /// The compiled regular expressions, by pattern id. Built on load and on every change.
    @ObservationIgnored private var compiled: [String: NSRegularExpression] = [:]

    @ObservationIgnored private let config: ConfigFile

    public enum Key {
        public static let ownNick = "highlight.nick"
        public static let prefix = "highlight."
    }

    public init(config: ConfigFile = .shared) {
        self.config = config
        self.matchesOwnNick = config.bool(Key.ownNick) ?? true
        var loaded: [HighlightPattern] = []
        for key in config.keys(withPrefix: Key.prefix).sorted(by: Self.byIndex) {
            guard Int(key.dropFirst(Key.prefix.count)) != nil,
                let value = config.string(key),
                let pattern = Self.parse(value)
            else { continue }
            loaded.append(pattern)
        }
        adopt(loaded)
    }

    /// `highlight.2` before `highlight.10`. `highlight.nick` is not an index and is skipped
    /// by the caller, so it sorts wherever.
    private static func byIndex(_ first: String, _ second: String) -> Bool {
        let left = Int(first.dropFirst(Key.prefix.count)) ?? Int.max
        let right = Int(second.dropFirst(Key.prefix.count)) ?? Int.max
        return left == right ? first < second : left < right
    }

    // MARK: - The list

    public func add(_ pattern: HighlightPattern) {
        var updated = patterns.filter { $0.id != pattern.id }
        updated.append(pattern)
        adopt(updated)
        write()
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        let updated = patterns.filter { $0.id != id }
        guard updated.count != patterns.count else { return false }
        adopt(updated)
        write()
        return true
    }

    /// Takes a new set and compiles the regular expressions in it, once.
    ///
    /// A pattern that will not compile is kept and left out of ``compiled``, which is what
    /// makes it visible in the form, removable, and unable to match.
    private func adopt(_ incoming: [HighlightPattern]) {
        var built: [String: NSRegularExpression] = [:]
        for pattern in incoming where pattern.kind == .regex {
            guard
                let expression = try? NSRegularExpression(
                    pattern: pattern.text,
                    options: [.caseInsensitive]
                )
            else { continue }
            built[pattern.id] = expression
        }
        patterns = incoming.filter { !$0.text.isEmpty }
        compiled = built
    }

    // MARK: - Matching

    /// Whether this line is worth your attention.
    ///
    /// Ordered cheapest first: the nick check is a scan, a word is a scan, and a regular
    /// expression is the only thing here that allocates. On a busy channel most lines match
    /// nothing, so the order is the whole cost.
    public func matches(_ text: String, ownNick: String) -> Bool {
        if matchesOwnNick, !ownNick.isEmpty, Self.containsWord(ownNick, in: text) { return true }
        for pattern in patterns where pattern.kind == .word {
            if Self.containsWord(pattern.text, in: text) { return true }
        }
        guard !compiled.isEmpty else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns where pattern.kind == .regex {
            guard let expression = compiled[pattern.id] else { continue }
            if expression.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    /// Whether `needle` appears in `text` as a word rather than as a fragment.
    ///
    /// **Moved here from `BufferActivity.mentions(_:in:)` unchanged in behaviour**, and now
    /// used for keywords as well as for your own nick — they want exactly the same rule.
    /// `bob` is mentioned by "bob: look" and by "thanks, bob!", and is not mentioned by
    /// "bobbins". Without the boundary check a short nick highlights on almost every line,
    /// which trains people to ignore the state entirely.
    ///
    /// A multi-word phrase works too: the boundary test looks at the characters either side
    /// of the whole run, so `build failed` matches "the build failed again".
    static func containsWord(_ needle: String, in text: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let haystack = Array(text.lowercased())
        let target = Array(needle.lowercased())
        guard haystack.count >= target.count else { return false }

        for start in 0...(haystack.count - target.count) {
            guard Array(haystack[start..<start + target.count]) == target else { continue }
            let before = start > 0 ? haystack[start - 1] : nil
            let afterIndex = start + target.count
            let after = afterIndex < haystack.count ? haystack[afterIndex] : nil
            if !isWordCharacter(before) && !isWordCharacter(after) { return true }
        }
        return false
    }

    /// Characters that can be part of a nickname, so a match butting up against one is a
    /// fragment rather than a mention. Digits count: `bob2` is not `bob`.
    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    // MARK: - The file

    /// `<kind> <pattern>`.
    ///
    /// **Split on the first space only**, which is the one deliberate difference from
    /// `ignore.<n>`'s format: a mask can never contain a space and a keyword phrase very
    /// often does. `word build failed` is one rule about two words, not a malformed line.
    static func parse(_ value: String) -> HighlightPattern? {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let kind = HighlightPattern.Kind(rawValue: String(parts[0]))
        else { return nil }
        let text = String(parts[1])
        guard !text.isEmpty else { return nil }
        return HighlightPattern(kind: kind, text: text)
    }

    static func format(_ pattern: HighlightPattern) -> String {
        "\(pattern.kind.rawValue) \(pattern.text)"
    }

    /// Rewrites every `highlight.<n>`, renumbering from one, and leaves `highlight.nick`
    /// alone — it is the one key in this family that is not an index.
    ///
    /// **A pattern that will not compile is written back too.** It is the user's, it is
    /// wrong, and silently deleting somebody's typo on the next save is a worse answer than
    /// showing it to them as broken.
    private func write() {
        for key in config.keys(withPrefix: Key.prefix) where key != Key.ownNick {
            config.set(nil, forKey: key)
        }
        for (index, pattern) in patterns.enumerated() {
            config.set(Self.format(pattern), forKey: "\(Key.prefix)\(index + 1)")
        }
    }
}
