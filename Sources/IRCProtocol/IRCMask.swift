/// Wildcard matching for `nick!user@host` masks, as used by bans and ignores.
///
/// `*` matches any run of characters including none; `?` matches exactly one. Nothing
/// else is special — `[` and `]` are literal, so `cool[guy]!*@*` matches a user
/// actually called `cool[guy]`.
public enum IRCMask {
    /// Whether `source` matches `mask` under `mapping`.
    public static func matches(
        mask: String,
        source: String,
        mapping: IRCCaseMapping = .rfc1459
    ) -> Bool {
        let pattern = Array(mapping.foldedCase(mask).unicodeScalars)
        let subject = Array(mapping.foldedCase(source).unicodeScalars)
        return glob(pattern: pattern, subject: subject)
    }

    /// Iterative glob with backtracking.
    ///
    /// Deliberately not recursive: a mask is user-supplied and something like
    /// `*a*a*a*a*b` against a long host would blow the stack under naive recursion,
    /// while this stays linear in practice.
    private static func glob(pattern: [Unicode.Scalar], subject: [Unicode.Scalar]) -> Bool {
        var patternIndex = 0
        var subjectIndex = 0
        var lastStar: Int?
        var resumeAt = 0

        while subjectIndex < subject.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                lastStar = patternIndex
                patternIndex += 1
                resumeAt = subjectIndex
            } else if patternIndex < pattern.count,
                pattern[patternIndex] == "?" || pattern[patternIndex] == subject[subjectIndex]
            {
                patternIndex += 1
                subjectIndex += 1
            } else if let star = lastStar {
                // Backtrack: let the last `*` swallow one more character.
                patternIndex = star + 1
                resumeAt += 1
                subjectIndex = resumeAt
            } else {
                return false
            }
        }

        // Any pattern left over must be all stars.
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}
