import Foundation
import IRCFormat

/// Which mIRC colour *indices* a run asked for, recorded so they can be resolved again.
///
/// The same division of labour as ``InlineTraits`` and ``NickColumn``: the renderer records
/// what a run *is* and the buffer decides what it *looks like*.
///
/// **This exists because a user override has to reach text already on screen.** Switching
/// between the light and dark tables needs no pass over the buffer at all — an indexed
/// colour goes into the storage as an appearance-resolving `NSColor` and re-reads itself
/// when the appearance changes. Retuning what index 4 *means* is a different kind of
/// change: it alters the value, not the appearance, and a colour already resolved into the
/// storage cannot know. Without this, changing a colour on the Colours tab left every line
/// above it in the old palette and every line below it in the new one, which is the exact
/// two-conventions-in-one-buffer failure the font and nick-colour settings avoid.
///
/// **Indices only, never hex.** `^D` names an exact value, and §5 is explicit that an
/// override does not apply to it — second-guessing a sender who was that specific would
/// overrule the one thing they were explicit about. A run with only hex colours records
/// nothing here and is left exactly as it was drawn.
public struct InlineColours: Sendable, Hashable {
    /// The foreground index, or `nil` for "the line's own colour".
    public var foreground: Int?

    /// The background index, or `nil` for "the window's own background".
    public var background: Int?

    /// `^R`. Resolved late, because swapping in the *window's* colours where one side is
    /// absent is something only the window knows how to do.
    public var isReversed: Bool

    public init(foreground: Int? = nil, background: Int? = nil, isReversed: Bool = false) {
        self.foreground = foreground
        self.background = background
        self.isReversed = isReversed
    }

    /// Whether there is anything here worth recording.
    var isEmpty: Bool { foreground == nil && background == nil && !isReversed }

    /// `fg,bg,r` with `-` for an absent index. A fixed three-field shape rather than
    /// anything cleverer: this is written once per styled run and parsed once per restyle,
    /// and the cheapest encoding that cannot be ambiguous is the one to use.
    var encoded: String {
        "\(foreground.map(String.init) ?? "-"),\(background.map(String.init) ?? "-"),\(isReversed ? "1" : "0")"
    }

    init?(encoded: String) {
        let fields = encoded.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        // A field that is neither `-` nor a number is a corrupt attribute rather than an
        // absent one, and silently reading it as absent would hide the corruption.
        func index(_ field: Substring) -> Int?? {
            field == "-" ? .some(nil) : Int(field).map { .some($0) }
        }
        guard let foreground = index(fields[0]), let background = index(fields[1]),
            fields[2] == "0" || fields[2] == "1"
        else { return nil }
        self.init(
            foreground: foreground,
            background: background,
            isReversed: fields[2] == "1"
        )
    }
}

/// The attribute key. Objective-C convertible for the same reason ``InlineTraits`` is: a
/// Swift-only attribute is silently dropped on the way into the text storage.
public enum InlineColoursAttribute: ObjectiveCConvertibleAttributedStringKey {
    public typealias Value = InlineColours
    public typealias ObjectiveCValue = NSString

    public static let name = "caravanInlineColours"

    public static func objectiveCValue(for value: InlineColours) throws -> NSString {
        value.encoded as NSString
    }

    public static func value(for object: NSString) throws -> InlineColours {
        guard let colours = InlineColours(encoded: object as String) else {
            throw CocoaError(.coderInvalidValue)
        }
        return colours
    }
}

extension NSAttributedString.Key {
    /// The same attribute, named for the AppKit side of the conversion.
    static let inlineColours = NSAttributedString.Key(InlineColoursAttribute.name)
}
