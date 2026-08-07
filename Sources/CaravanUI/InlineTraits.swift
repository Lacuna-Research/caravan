import AppKit
import Foundation
import IRCFormat

/// The parts of a run's style that are properties of the *font* rather than of the text.
///
/// They travel as an attribute rather than as a font because `NSFont` is not `Sendable`
/// and Swift 6 will not let one into an `AttributedString`. `MessageLogController` reads
/// this when it fills in the chat font, which is also the only place that knows what the
/// chat font currently is — so a font change restyles bold text back into bold text
/// instead of flattening it.
public struct InlineTraits: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let bold = InlineTraits(rawValue: 1 << 0)
    public static let italic = InlineTraits(rawValue: 1 << 1)
    public static let monospaced = InlineTraits(rawValue: 1 << 2)

    init(style: InlineStyle) {
        var traits: InlineTraits = []
        if style.isBold { traits.insert(.bold) }
        if style.isItalic { traits.insert(.italic) }
        if style.isMonospaced { traits.insert(.monospaced) }
        self = traits
    }

    /// `font` wearing these traits.
    ///
    /// **Monospace is a no-op here, deliberately.** The whole buffer is already
    /// monospaced by rule (GUI-DESIGN-NOTES.md §15), so `^M` has nothing to switch to.
    /// Kept as a trait rather than dropped at the parser, because the day a proportional
    /// buffer becomes an option this is where it starts mattering.
    /// **Rebuilt from the family, not converted from the font.** Adding `.bold` to a
    /// resolved font's descriptor returns a font — just not a bold one, because that
    /// descriptor names a specific face and the name wins over the added trait.
    /// `NSFontManager.convert` fails the same way here, because the chat font carries a
    /// cascade list. Going back to the family is what actually produces Menlo-Bold, and it
    /// keeps the fallback cascade, which a bold run needs every bit as much as a plain one.
    ///
    /// Caught by a test that asserted the glyphs were bold rather than that the call
    /// returned something.
    @MainActor
    func applied(to font: NSFont) -> NSFont {
        guard !isEmpty else { return font }
        var symbolic: NSFontDescriptor.SymbolicTraits = []
        if contains(.bold) { symbolic.insert(.bold) }
        // A monospaced face may have no italic cut, in which case the descriptor resolves
        // back to the plain one and the grid survives. Synthesising a slant would not, and
        // a broken grid is the one thing the font rules exist to prevent.
        if contains(.italic) { symbolic.insert(.italic) }
        guard !symbolic.isEmpty else { return font }
        return ChatFont.nsFont(
            family: font.familyName ?? ChatFont.defaultFamily,
            size: font.pointSize,
            traits: symbolic
        )
    }
}

/// The attribute key. Objective-C convertible on purpose: `AttributedString` values are
/// converted to `NSAttributedString` before they reach the text storage, and a Swift-only
/// custom attribute is silently dropped by that conversion.
public enum InlineTraitsAttribute: ObjectiveCConvertibleAttributedStringKey {
    public typealias Value = InlineTraits
    public typealias ObjectiveCValue = NSNumber

    public static let name = "caravanInlineTraits"

    public static func objectiveCValue(for value: InlineTraits) throws -> NSNumber {
        NSNumber(value: value.rawValue)
    }

    public static func value(for object: NSNumber) throws -> InlineTraits {
        InlineTraits(rawValue: object.uint8Value)
    }
}

extension AttributeScopes {
    public struct CaravanAttributes: AttributeScope {
        public let inlineTraits: InlineTraitsAttribute
        public let nickColumn: NickColumnAttribute
        public let inlineColours: InlineColoursAttribute

        /// **Nested, and load-bearing.** `NSAttributedString(_:including:)` carries the
        /// named scope and *only* the named scope, so a scope holding nothing but our two
        /// attributes converts a fully styled line into an unstyled one — no colours, no
        /// underlines, no links. The reason for naming a scope at all is that the default
        /// conversion drops the custom attributes; naming ours has to bring AppKit's
        /// along or it trades one silent loss for a much larger one.
        public let appKit: AttributeScopes.AppKitAttributes
    }

    public var caravan: CaravanAttributes.Type { CaravanAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.CaravanAttributes, T>
    ) -> T {
        self[T.self]
    }
}

extension NSAttributedString.Key {
    /// The same attribute, named for the AppKit side of the conversion.
    static let inlineTraits = NSAttributedString.Key(InlineTraitsAttribute.name)
}
