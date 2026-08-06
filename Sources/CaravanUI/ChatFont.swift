import AppKit
import SwiftUI

/// The chat font, and the rules that keep a monospaced grid actually monospaced.
///
/// In an IRC client the font is a correctness constraint rather than a taste preference:
/// ASCII and ANSI art are part of the culture, and a glyph that renders 1.8 cells wide
/// destroys art as thoroughly as a missing one.
///
/// **Menlo, decided by measurement.** `Scripts/font-coverage.swift` measures glyph
/// coverage *and* advance width against the cell for every system monospaced font; rerun
/// it before revisiting this. At 13pt Menlo carries all 44 characters of the CP437 art
/// set with nothing off-grid, where `NSFont.monospacedSystemFont` — SF Mono — is missing
/// eleven of them (`▬ ► ◄ ☺ ☻ ♠ ♣ ♥ ♦ ♪ ♫`), precisely the high-ASCII staples of BBS- and
/// mIRC-era art. Missing glyphs are not blanks: CoreText substitutes from another font,
/// and a proportional substitute measures up to 1.80× the cell.
///
/// **One chat font** governs the scrollback, the input box, the header band, the nick
/// list and the tree together. If the input box does not match the scrollback, what you
/// type does not look like what you send.
public enum ChatFont {
    /// The default family. SF Mono remains selectable — it is a good-looking font that
    /// happens to be wrong for art.
    public static let defaultFamily = "Menlo"

    public static let defaultSize: Double = 13

    /// The fallback cascade, monospaced only.
    ///
    /// Left alone, CoreText resolves a missing glyph by reaching for whatever font has
    /// it, proportional ones included — which is the 1.80× failure the measurement found.
    /// An explicit cascade replaces that choice, and a glyph missing from every font in
    /// it renders as a placeholder box: a broken character rather than a broken grid.
    ///
    /// Andale Mono comes first because it carries the whole CP437 set (44/44) despite
    /// thin box-drawing coverage — it covers exactly what Menlo would be missing if a
    /// user picked a different primary.
    public static let fallbackFamilies = ["Andale Mono", "Courier New"]

    /// The families the settings form offers, filtered to those actually installed.
    ///
    /// A short list of known-good monospaced faces rather than every font on the machine.
    /// A font picker showing Helvetica is a picker offering to break the grid the whole
    /// design rests on, and nothing downstream can un-break it. The config file is still
    /// plain text, so anyone who wants a font that is not here can write it in and live
    /// with the consequences — which is the right place for that decision.
    @MainActor
    public static func selectableFamilies(including current: String? = nil) -> [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        var families = ["Menlo", "SF Mono", "Monaco", "Andale Mono", "Courier New"]
            .filter(installed.contains)
        // Whatever the config says, even if we would not have offered it: a picker with
        // no row matching the current value shows a blank, which reads as a bug.
        if let current, !families.contains(current) {
            families.insert(current, at: 0)
        }
        return families
    }

    /// The font to render chat in.
    ///
    /// Falls back to the system monospaced font only if the requested family and every
    /// fallback are absent, which on macOS means something is very wrong — but a client
    /// that renders nothing is worse than one that renders in the wrong font.
    /// - Parameter traits: Bold and italic, for the runs that ask for them.
    ///   Applied to a descriptor built from the *family* rather than to one taken off an
    ///   already-resolved font: a resolved descriptor names a specific face, the name wins
    ///   over the added trait, and you get a font back that is simply not bold.
    @MainActor
    public static func nsFont(
        family: String = defaultFamily,
        size: Double = defaultSize,
        traits: NSFontDescriptor.SymbolicTraits = []
    ) -> NSFont {
        let cascade = fallbackFamilies.map {
            NSFontDescriptor(fontAttributes: [.family: $0])
        }
        var descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .cascadeList: cascade,
        ])
        if !traits.isEmpty {
            descriptor = descriptor.withSymbolicTraits(traits)
        }
        return NSFont(descriptor: descriptor, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The same font for SwiftUI chrome that has to line up with the scrollback.
    public static func font(family: String = defaultFamily, size: Double = defaultSize) -> Font {
        .custom(family, fixedSize: size)
    }

    /// How much taller than its natural line height one line may become.
    ///
    /// Combining marks and Zalgo text can blow a single line to hundreds of points, and
    /// this *will* be pasted into a channel. Generous enough for real diacritics, hard
    /// enough to stop the attack.
    static let lineHeightClamp: CGFloat = 1.6

    /// The paragraph style every chat line is drawn with.
    ///
    /// Two things it deliberately does *not* do: no `headIndent`, so a wrapped line
    /// continues flush-left at column 0 rather than hanging-indented under the message
    /// column — mIRC's shape — and no paragraph spacing, so messages sit directly under
    /// one another.
    @MainActor
    static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.maximumLineHeight = ceil(defaultLineHeight(for: font) * lineHeightClamp)
        return style
    }

    /// The style for a line that must never wrap — the unread rule, which is deliberately
    /// longer than any window so that it spans the width whatever the width is.
    @MainActor
    static func clippingParagraphStyle(for font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(paragraphStyle(for: font))
        style.lineBreakMode = .byClipping
        return style
    }

    /// A line's natural height in the given font.
    @MainActor
    static func defaultLineHeight(for font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    /// Ligatures are off unconditionally, even when the user's font has them: a coding
    /// font turns `!=` into `≠` and `->` into an arrow, mangling quoted code and art
    /// alike. Applied where the text is built, in ``MessageLogController``.
}

extension EnvironmentValues {
    /// The one chat font, handed down from the root.
    ///
    /// An environment value rather than a parameter threaded through five views: the
    /// requirement is that the scrollback, the input box, the header band, the nick list
    /// and the tree all use the *same* font, and a value every view reads from one place
    /// is how that stays true when a sixth is added.
    @Entry public var chatFont: Font = ChatFont.font()
}
