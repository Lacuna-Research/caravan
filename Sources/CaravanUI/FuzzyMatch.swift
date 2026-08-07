import Foundation

/// Subsequence matching with a score, for the ⌘K quick-switcher (GUI-DESIGN-NOTES.md §9).
///
/// Pure, and its own type, because ranking is the whole of whether a palette feels right:
/// typing `sw` must put `#swift` above `Libera.Chat/#news-worldwide`, and that is an
/// arithmetic claim a test can make rather than something to eyeball.
///
/// **Names only.** ⌘F-in-buffer and full-text history search stay separate features with
/// their own UI — a palette that searched message bodies would return a different *kind*
/// of result for the same keystrokes depending on what you typed.
public enum FuzzyMatch {
    /// How well `query` matches `candidate`, or `nil` for no match at all.
    ///
    /// Higher is better. An empty query matches everything equally, which is what makes
    /// the palette list every buffer before you type.
    public static func score(_ query: String, in candidate: String) -> Int? {
        // **Spaces are dropped from the query, not matched.** The live run reached for
        // `libera nav-11` to pick one of two identically named channels, and it found
        // nothing: the candidate is `Libera.Chat/##caravan-nav-11`, with a slash where the
        // space was. Treating a space as "and then, later" is what people mean by it.
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())
        let original = Array(candidate)

        var score = 0
        var haystackIndex = 0
        var previousMatch: Int?

        for character in needle {
            // Find this character at or after where the last one matched. Greedy-leftmost:
            // an optimal aligner would cost more than a list of thirty buffers is worth.
            guard let found = haystack[haystackIndex...].firstIndex(of: character) else {
                return nil
            }
            score += 1
            // Adjacent characters are worth much more than scattered ones, which is what
            // makes `swi` prefer `#swift` to `#some-wild-thing`.
            if let previousMatch, found == previousMatch + 1 { score += 8 }
            // So is landing at the start of a word or after a separator: people type the
            // initials of what they are looking for.
            if isBoundary(before: found, in: original) { score += 6 }
            previousMatch = found
            haystackIndex = found + 1
        }

        // A shorter name containing the same match is the better answer: `#go` beats
        // `#golang-newcomers` for `go`. Bounded so it can never outweigh a real match.
        score += max(0, 12 - candidate.count / 4)
        return score
    }

    /// Whether the character at `index` begins a word.
    ///
    /// A channel's `#`, a separator, or a capital in the middle of a name — so `LC` finds
    /// `LiberaChat` and `ls` finds `Libera/#swift`.
    private static func isBoundary(before index: Int, in characters: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if !previous.isLetter && !previous.isNumber { return true }
        return previous.isLowercase && characters[index].isUppercase
    }

    /// The buffers matching `query`, best first.
    ///
    /// Matched against the **qualified** name — `Libera.Chat/#swift` — so typing part of a
    /// network narrows to it, which is the only way to tell two identically named channels
    /// apart in a flat list (§12).
    ///
    /// **An empty query lists the buffers in the order they were given**, which is the
    /// tree's own order. The live run showed the alternative: with every score equal, the
    /// list fell back to shortest-then-alphabetical, so an unfiltered palette put
    /// `##caravan-nav-10` above `##caravan-nav-2`. A palette you have not typed into
    /// should look like the tree you were just looking at.
    ///
    /// Ties break on **activity first**, then on the qualified name. Two buffers matching
    /// a query equally well are not equally interesting — the live run typed `nav-11`,
    /// matched one channel on each network, and landed on the quiet one rather than the
    /// one holding a highlight. Name last, so the order is stable rather than dependent on
    /// whatever `sort` felt like: a list that reshuffles between keystrokes is one where
    /// Enter lands somewhere you did not look at.
    public static func rank(_ buffers: [BufferRef], query: String) -> [BufferRef] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return buffers }
        return
            buffers
            .compactMap { buffer -> (BufferRef, Int)? in
                guard let score = score(query, in: buffer.qualifiedName) else { return nil }
                return (buffer, score)
            }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                if left.0.activity != right.0.activity {
                    return left.0.activity > right.0.activity
                }
                return left.0.qualifiedName < right.0.qualifiedName
            }
            .map(\.0)
    }
}
