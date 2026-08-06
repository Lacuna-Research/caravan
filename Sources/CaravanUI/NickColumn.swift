import Foundation

/// The nick column of a line, recorded so its colour can be decided again later.
///
/// The same division of labour as ``InlineTraits``: the renderer records what a run *is*
/// and the buffer decides what it *looks like*. Turning nick colouring off has to reach
/// text already on screen — a toggle that applied only to the next line to arrive would
/// leave the buffer in two conventions, which is worse than not offering it — and putting
/// the nick back in the line's own colour means knowing what the line's own colour was.
public struct NickColumn: Sendable, Hashable {
    /// The bare nick, without any channel prefix.
    ///
    /// Without, because the hash is seeded on the name alone (§6): `@bob` and `bob` are
    /// one person, and hashing the decorated form would give him one colour in a channel
    /// where he is opped and another in a channel where he is not.
    public var nick: String

    /// The colour the rest of the line wears, and the one the nick falls back to when
    /// colouring is off.
    public var base: LineColour

    public init(nick: String, base: LineColour) {
        self.nick = nick
        self.base = base
    }

    /// `role|nick`. The role first, and split at the *first* separator: `|` is a legal
    /// character in a nick and an illegal one in a ``LineColour`` case name, so this is
    /// the only split that cannot be fooled by somebody called `a|b`.
    var encoded: String { "\(base.rawValue)|\(nick)" }

    init?(encoded: String) {
        guard let separator = encoded.firstIndex(of: "|"),
            let base = LineColour(rawValue: String(encoded[encoded.startIndex..<separator]))
        else { return nil }
        self.init(nick: String(encoded[encoded.index(after: separator)...]), base: base)
    }
}

/// The attribute key. Objective-C convertible for the same reason ``InlineTraits`` is: a
/// Swift-only attribute is silently dropped on the way into the text storage.
public enum NickColumnAttribute: ObjectiveCConvertibleAttributedStringKey {
    public typealias Value = NickColumn
    public typealias ObjectiveCValue = NSString

    public static let name = "caravanNickColumn"

    public static func objectiveCValue(for value: NickColumn) throws -> NSString {
        value.encoded as NSString
    }

    public static func value(for object: NSString) throws -> NickColumn {
        guard let column = NickColumn(encoded: object as String) else {
            throw CocoaError(.coderInvalidValue)
        }
        return column
    }
}

extension NSAttributedString.Key {
    /// The same attribute, named for the AppKit side of the conversion.
    static let nickColumn = NSAttributedString.Key(NickColumnAttribute.name)
}
