/// How a server compares nicknames and channel names for equality.
///
/// Advertised by `ISUPPORT CASEMAPPING`. It matters more than it looks: under
/// `rfc1459` the nicks `Foo[]` and `foo{}` are the same user, so any dictionary keyed
/// by nickname must fold with the mapping the server actually declared, not with
/// `lowercased()`.
public enum IRCCaseMapping: String, Sendable, Hashable, CaseIterable {
    /// `A-Z` only.
    case ascii

    /// ASCII plus `[]\~` as the uppercase forms of `{}|^`.
    ///
    /// The `~`/`^` pair is the historical quirk: RFC 1459 declared it, and
    /// `strict-rfc1459` later dropped it.
    case rfc1459

    /// ASCII plus `[]\` as the uppercase forms of `{}|`, without the `~`/`^` pair.
    case rfc1459Strict

    /// The token as it appears in `ISUPPORT`.
    public var token: String {
        switch self {
        case .ascii: "ascii"
        case .rfc1459: "rfc1459"
        case .rfc1459Strict: "strict-rfc1459"
        }
    }

    /// Parses an `ISUPPORT CASEMAPPING` token. Unknown mappings return `nil` so the
    /// caller can decide what to fall back to rather than silently guessing.
    public init?(token: String) {
        switch token.lowercased() {
        case "ascii": self = .ascii
        case "rfc1459": self = .rfc1459
        case "strict-rfc1459": self = .rfc1459Strict
        default: return nil
        }
    }

    /// Folds `text` to its canonical lowercase form under this mapping.
    public func foldedCase(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map(fold)))
    }

    /// Whether two strings name the same entity under this mapping.
    public func equal(_ lhs: String, _ rhs: String) -> Bool {
        foldedCase(lhs) == foldedCase(rhs)
    }

    /// Folds one scalar to its lowercase form.
    ///
    /// RFC 1459: "Because of IRC's Scandinavian origin, the characters `{}|^` are
    /// considered to be the lower case equivalents of the characters `[]\~`."
    func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if ("A"..."Z").contains(scalar) {
            return Unicode.Scalar(scalar.value + 32) ?? scalar
        }
        guard self != .ascii else { return scalar }
        switch scalar {
        case "[", "]", "\\":
            // [ -> {   ] -> }   \ -> |
            return Unicode.Scalar(scalar.value + 32) ?? scalar
        case "~" where self == .rfc1459:
            // ~ -> ^, the pair strict-rfc1459 drops.
            return "^"
        default:
            return scalar
        }
    }
}
