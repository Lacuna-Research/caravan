import Foundation
import IRCSession

/// What Tab has to choose from, at the moment it is pressed.
///
/// A snapshot rather than a live reference: completion is a decision made against the
/// channel as it was when you pressed Tab, and a list that changed underneath a cycle
/// would step to a different candidate than the one you saw.
public struct CompletionSources: Sendable, Equatable {
    /// Nicks in the order the nick list shows them — rank, then casemapped alphabetical.
    /// Kept as the session's ordering rather than re-sorted: a second sort here is a
    /// second answer to a question `Channel` has already answered.
    public var nicks: [String]

    /// Channels to offer for a `#`-prefixed word. The ones this connection has open, so
    /// nothing here needs a round trip — completing against `LIST` output is the thing
    /// the prompt fences off.
    public var channels: [String]

    /// Command verbs, without their slash.
    public var commands: [String]

    public init(nicks: [String] = [], channels: [String] = [], commands: [String] = []) {
        self.nicks = nicks
        self.channels = channels
        self.commands = commands
    }

    /// The commands the parser knows, which is the only list that is not a guess.
    public static let allCommands = CommandParser.knownCommands
}

/// What a completed nick is followed by.
///
/// Separate from ``CompletionSources`` because it is a *setting* rather than a candidate:
/// the sources change with the channel, this changes only when the user says so. mIRC has
/// had this configurable for decades and people are particular about it — `bob, ` and
/// `bob> ` are both in the wild.
public struct CompletionStyle: Sendable, Equatable {
    /// After a nick that opens the line — an address.
    public var atLineStart: String

    /// After a nick anywhere else — a word in a sentence.
    public var elsewhere: String

    public init(atLineStart: String = ": ", elsewhere: String = " ") {
        self.atLineStart = atLineStart
        self.elsewhere = elsewhere
    }
}

/// mIRC-style cycling Tab completion.
///
/// Pure and caret-indexed: it takes text and an offset and gives back text and an offset,
/// so every rule here is testable without a text view. `InputTextView` owns the keys, this
/// owns the decision.
///
/// **The cycle is the whole point.** Tab once takes the first match; Tab again replaces it
/// with the second rather than completing the completion, which is what mIRC does and what
/// makes a channel of five people whose names share a prefix usable at all.
@MainActor
public final class TabCompletion {
    /// A cycle in progress: what was being completed, where, and what is left to offer.
    private struct Cycle {
        /// The stretch of text the completion currently occupies, including its suffix.
        var range: Range<Int>
        /// What the user actually typed, which every candidate is measured against.
        var stem: String
        var candidates: [String]
        var index: Int
        /// The suffix in force for this cycle: `": "` when the word opened the line.
        var suffix: String
    }

    private var cycle: Cycle?

    public init() {}

    /// The result of a Tab: the whole new text, and where the caret goes.
    public struct Completion: Sendable, Equatable {
        public var text: String
        public var caret: Int
    }

    /// Whether a cycle is in progress. For tests, and for deciding whether Shift+Tab has
    /// anything to step back through.
    public var isCycling: Bool { cycle != nil }

    /// Ends any cycle in progress, committing whatever is in the box.
    ///
    /// Called when the user types anything else. Committing is the *absence* of an action:
    /// the completed text is already there and simply stops being replaceable, which is
    /// why this returns nothing.
    public func commit() {
        cycle = nil
    }

    /// Completes the word at `caret`, or steps to the next candidate if already cycling.
    ///
    /// Returns `nil` when there is nothing to complete — no word, or no match — and the
    /// caller lets Tab do whatever it would have done.
    public func complete(
        text: String,
        caret: Int,
        sources: CompletionSources,
        style: CompletionStyle = CompletionStyle(),
        backwards: Bool = false
    ) -> Completion? {
        if let stepped = step(text: text, caret: caret, backwards: backwards) {
            return stepped
        }
        cycle = nil

        let characters = Array(text)
        let caret = min(max(caret, 0), characters.count)
        let start = wordStart(in: characters, before: caret)
        let stem = String(characters[start..<caret])
        guard !stem.isEmpty else { return nil }

        let kind = Kind(stem: stem)
        // A command only at the very start of the box: `/msg bob /me` is a message that
        // contains a slash, and completing it would rewrite somebody's sentence.
        guard kind != .command || start == 0 else { return nil }
        let candidates = kind.candidates(for: stem, in: sources)
        guard !candidates.isEmpty else { return nil }
        let suffix = kind.suffix(
            atLineStart: isLineStart(in: characters, at: start),
            style: style
        )

        let index = backwards ? candidates.count - 1 : 0
        return apply(
            Cycle(
                range: start..<caret,
                stem: stem,
                candidates: candidates,
                index: index,
                suffix: suffix
            ),
            to: characters
        )
    }

    /// The next candidate in an existing cycle, if this Tab continues one.
    ///
    /// A cycle survives only while the text and caret are exactly where the last
    /// completion left them. Anything else — a keystroke, a click elsewhere — means the
    /// user moved on, and a cycle that resumed after that would rewrite text they had
    /// gone back to edit.
    private func step(text: String, caret: Int, backwards: Bool) -> Completion? {
        guard var cycle, cycle.candidates.count > 0, caret == cycle.range.upperBound else {
            return nil
        }
        let characters = Array(text)
        guard cycle.range.upperBound <= characters.count,
            String(characters[cycle.range]) == completed(cycle)
        else { return nil }

        let count = cycle.candidates.count
        cycle.index = ((cycle.index + (backwards ? -1 : 1)) % count + count) % count
        return apply(cycle, to: characters)
    }

    /// Writes a cycle's current candidate into the text and records it as the live cycle.
    private func apply(_ cycle: Cycle, to characters: [Character]) -> Completion {
        var cycle = cycle
        var characters = characters
        let replacement = Array(completed(cycle))
        characters.replaceSubrange(cycle.range, with: replacement)
        cycle.range = cycle.range.lowerBound..<(cycle.range.lowerBound + replacement.count)
        self.cycle = cycle
        return Completion(text: String(characters), caret: cycle.range.upperBound)
    }

    private func completed(_ cycle: Cycle) -> String {
        cycle.candidates[cycle.index] + cycle.suffix
    }

    // MARK: - What is being completed

    /// What is being completed, decided once from the shape of the word.
    ///
    /// **Once**, because both the candidates and the suffix depend on it and deciding
    /// them separately gets them out of step — which is exactly how `#swift` first came
    /// back as `#swift: `, addressing a channel as though it were a person.
    ///
    /// No fallback between the three: offering nicks for `/jo` would put a nick where a
    /// command belongs and send it to the server as one.
    private enum Kind {
        case command
        case channel
        case nick

        init(stem: String) {
            if stem.hasPrefix("/") {
                self = .command
            } else if let first = stem.first, TabCompletion.channelPrefixes.contains(first) {
                self = .channel
            } else {
                self = .nick
            }
        }

        func candidates(for stem: String, in sources: CompletionSources) -> [String] {
            switch self {
            case .command:
                return matches(for: String(stem.dropFirst()), in: sources.commands)
                    .map { "/\($0)" }
            case .channel:
                return matches(for: stem, in: sources.channels)
            case .nick:
                return matches(for: stem, in: sources.nicks)
            }
        }

        /// The address suffix only for a nick opening the line (§7, and mIRC's rule) — the
        /// thing that makes `bob: hello` an address and `tell bob about it` a sentence. A
        /// channel or a command is a word in a sentence, never something you address, so
        /// neither takes the address form however it is configured.
        func suffix(atLineStart: Bool, style: CompletionStyle) -> String {
            self == .nick && atLineStart ? style.atLineStart : style.elsewhere
        }

        /// Case-insensitive prefix matches, in the order the source gave them.
        ///
        /// Case-insensitively, because you should not have to know whether someone spells
        /// themselves `Bob` or `bob` to complete them — and the completion arrives in
        /// *their* spelling, which is the one that will match on the wire.
        private func matches(for stem: String, in candidates: [String]) -> [String] {
            let folded = stem.lowercased()
            return candidates.filter { $0.lowercased().hasPrefix(folded) }
        }
    }

    /// Whether the word at `start` is the first thing on its line.
    private func isLineStart(in characters: [Character], at start: Int) -> Bool {
        var index = start - 1
        while index >= 0 {
            if characters[index] == "\n" { return true }
            guard characters[index] == " " || characters[index] == "\t" else { return false }
            index -= 1
        }
        return true
    }

    /// Back from the caret to the start of the word being typed.
    private func wordStart(in characters: [Character], before caret: Int) -> Int {
        var index = caret
        while index > 0, !characters[index - 1].isWhitespace {
            index -= 1
        }
        return index
    }

    /// The characters that mark a word as a channel name.
    ///
    /// Not read from `ISUPPORT`: this is a guess about what the user is typing, made
    /// before anything is sent, and the two RFC types cover every network anyone types by
    /// hand. A wrong guess costs a completion, not a message.
    nonisolated static let channelPrefixes: Set<Character> = ["#", "&"]
}
