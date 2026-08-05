/// A command: either a textual verb or a three-digit numeric reply.
public enum IRCCommand: Sendable, Hashable {
    case verb(String)
    case numeric(UInt16)

    /// Classifies a raw command token.
    ///
    /// Exactly three ASCII digits is a numeric; anything else is a verb. `01` and
    /// `0001` are verbs, because the protocol says numerics are three digits and
    /// pretending otherwise would invent replies that cannot exist.
    public init(token: String) {
        let digits = token.unicodeScalars
        if digits.count == 3, digits.allSatisfy({ ("0"..."9").contains($0) }),
            let value = UInt16(token)
        {
            self = .numeric(value)
        } else {
            self = .verb(token)
        }
    }

    /// The token as it appears on the wire.
    ///
    /// Numerics are always three digits: `001`, not `1`. Losing the padding produces a
    /// line no server will accept.
    public var wireForm: String {
        switch self {
        case .verb(let verb):
            return verb
        case .numeric(let code):
            let digits = String(code)
            return String(repeating: "0", count: max(0, 3 - digits.count)) + digits
        }
    }

    /// Case-insensitive verb comparison, since commands are case-insensitive on the
    /// wire even though we preserve the case we received.
    public func isVerb(_ other: String) -> Bool {
        guard case .verb(let verb) = self else { return false }
        return verb.uppercased() == other.uppercased()
    }

    public var numericCode: UInt16? {
        if case .numeric(let code) = self { return code }
        return nil
    }
}
