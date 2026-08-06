/// The mIRC colour palettes, as RGB triples.
///
/// Triples rather than `NSColor` so this module stays pure and CI can keep building it on
/// Linux. Turning an index into something a text view can draw is `CaravanUI`'s job, and
/// it is the only thing that should know which background the window has.
///
/// **Two base palettes, not one with white and black swapped** (GUI-DESIGN-NOTES.md §5).
/// mIRC's sixteen were chosen against a white background: index 0 is white and index 1 is
/// black, so rendering them literally on a dark background makes a large fraction of
/// pasted text unreadable. Swapping only those two leaves the other fourteen still tuned
/// for white — dark blue on black is as unreadable as white on white. The extended 16–98
/// range is fixed RGB in the specification and survives unchanged.
///
/// Source: <https://modern.ircdocs.horse/formatting>, fetched and checked against this
/// table rather than recalled.
public enum MIRCPalette {
    /// Indices 0–15 against a light background. mIRC's own values.
    public static let light: [RGB] = [
        RGB(0xFF, 0xFF, 0xFF),  // 0  white
        RGB(0x00, 0x00, 0x00),  // 1  black
        RGB(0x00, 0x00, 0x7F),  // 2  blue
        RGB(0x00, 0x93, 0x00),  // 3  green
        RGB(0xFF, 0x00, 0x00),  // 4  red
        RGB(0x7F, 0x00, 0x00),  // 5  brown
        RGB(0x9C, 0x00, 0x9C),  // 6  magenta
        RGB(0xFC, 0x7F, 0x00),  // 7  orange
        RGB(0xFF, 0xFF, 0x00),  // 8  yellow
        RGB(0x00, 0xFC, 0x00),  // 9  light green
        RGB(0x00, 0x93, 0x93),  // 10 cyan
        RGB(0x00, 0xFF, 0xFF),  // 11 light cyan
        RGB(0x00, 0x00, 0xFC),  // 12 light blue
        RGB(0xFF, 0x00, 0xFF),  // 13 pink
        RGB(0x7F, 0x7F, 0x7F),  // 14 grey
        RGB(0xD2, 0xD2, 0xD2),  // 15 light grey
    ]

    /// Indices 0–15 against a dark background.
    ///
    /// Luminance-adjusted rather than hue-shifted: every entry keeps its name — 2 is still
    /// blue, 5 is still brown — and only its lightness moves, so a sender's intent
    /// survives. The dark blues and browns are lifted until they clear the contrast floor
    /// against near-black, and the pale entries are pulled down so they stop glaring.
    ///
    /// **Index 1 is the awkward one.** "Black" on a near-black window is invisible, so on
    /// this palette it becomes a light grey — distinguishable from 0 (white), 14 and 15,
    /// which keeps the greyscale ladder ordered even though "black" now reads light. The
    /// case that would break — `^C1,0`, black on white — does not use this table at all:
    /// see ``resolving(foreground:background:appearance:)``.
    public static let dark: [RGB] = [
        RGB(0xFF, 0xFF, 0xFF),  // 0  white
        RGB(0xD0, 0xD0, 0xD0),  // 1  "black" — lightened, or it is invisible
        RGB(0x5A, 0x7B, 0xFF),  // 2  blue      — lifted off near-black
        RGB(0x3A, 0xD9, 0x3A),  // 3  green
        RGB(0xFF, 0x5C, 0x5C),  // 4  red
        RGB(0xC4, 0x6A, 0x4A),  // 5  brown     — lifted; still reads brown
        RGB(0xD9, 0x6A, 0xD9),  // 6  magenta
        RGB(0xFF, 0xA5, 0x3C),  // 7  orange
        RGB(0xFF, 0xF7, 0x5C),  // 8  yellow
        RGB(0x66, 0xFF, 0x66),  // 9  light green
        RGB(0x3C, 0xC8, 0xC8),  // 10 cyan
        RGB(0x6A, 0xFF, 0xFF),  // 11 light cyan
        RGB(0x8A, 0xA5, 0xFF),  // 12 light blue
        RGB(0xFF, 0x8A, 0xFF),  // 13 pink
        RGB(0xA0, 0xA0, 0xA0),  // 14 grey
        RGB(0x6E, 0x6E, 0x6E),  // 15 light grey — darkened; it is a *background* grey
    ]

    /// Indices 16–98, fixed by the specification and shared by both appearances.
    public static let extended: [RGB] = [
        RGB(0x47, 0x00, 0x00), RGB(0x47, 0x21, 0x00), RGB(0x47, 0x47, 0x00),
        RGB(0x32, 0x47, 0x00), RGB(0x00, 0x47, 0x00), RGB(0x00, 0x47, 0x2C),
        RGB(0x00, 0x47, 0x47), RGB(0x00, 0x27, 0x47), RGB(0x00, 0x00, 0x47),
        RGB(0x2E, 0x00, 0x47), RGB(0x47, 0x00, 0x47), RGB(0x47, 0x00, 0x2A),
        RGB(0x74, 0x00, 0x00), RGB(0x74, 0x3A, 0x00), RGB(0x74, 0x74, 0x00),
        RGB(0x51, 0x74, 0x00), RGB(0x00, 0x74, 0x00), RGB(0x00, 0x74, 0x49),
        RGB(0x00, 0x74, 0x74), RGB(0x00, 0x40, 0x74), RGB(0x00, 0x00, 0x74),
        RGB(0x4B, 0x00, 0x74), RGB(0x74, 0x00, 0x74), RGB(0x74, 0x00, 0x45),
        RGB(0xB5, 0x00, 0x00), RGB(0xB5, 0x63, 0x00), RGB(0xB5, 0xB5, 0x00),
        RGB(0x7D, 0xB5, 0x00), RGB(0x00, 0xB5, 0x00), RGB(0x00, 0xB5, 0x71),
        RGB(0x00, 0xB5, 0xB5), RGB(0x00, 0x63, 0xB5), RGB(0x00, 0x00, 0xB5),
        RGB(0x75, 0x00, 0xB5), RGB(0xB5, 0x00, 0xB5), RGB(0xB5, 0x00, 0x6B),
        RGB(0xFF, 0x00, 0x00), RGB(0xFF, 0x8C, 0x00), RGB(0xFF, 0xFF, 0x00),
        RGB(0xB2, 0xFF, 0x00), RGB(0x00, 0xFF, 0x00), RGB(0x00, 0xFF, 0xA0),
        RGB(0x00, 0xFF, 0xFF), RGB(0x00, 0x8C, 0xFF), RGB(0x00, 0x00, 0xFF),
        RGB(0xA5, 0x00, 0xFF), RGB(0xFF, 0x00, 0xFF), RGB(0xFF, 0x00, 0x98),
        RGB(0xFF, 0x59, 0x59), RGB(0xFF, 0xB4, 0x59), RGB(0xFF, 0xFF, 0x71),
        RGB(0xCF, 0xFF, 0x60), RGB(0x6F, 0xFF, 0x6F), RGB(0x65, 0xFF, 0xC9),
        RGB(0x6D, 0xFF, 0xFF), RGB(0x59, 0xB4, 0xFF), RGB(0x59, 0x59, 0xFF),
        RGB(0xC4, 0x59, 0xFF), RGB(0xFF, 0x66, 0xFF), RGB(0xFF, 0x59, 0xBC),
        RGB(0xFF, 0x9C, 0x9C), RGB(0xFF, 0xD3, 0x9C), RGB(0xFF, 0xFF, 0x9C),
        RGB(0xE2, 0xFF, 0x9C), RGB(0x9C, 0xFF, 0x9C), RGB(0x9C, 0xFF, 0xDB),
        RGB(0x9C, 0xFF, 0xFF), RGB(0x9C, 0xD3, 0xFF), RGB(0x9C, 0x9C, 0xFF),
        RGB(0xDC, 0x9C, 0xFF), RGB(0xFF, 0x9C, 0xFF), RGB(0xFF, 0x94, 0xD3),
        RGB(0x00, 0x00, 0x00), RGB(0x13, 0x13, 0x13), RGB(0x28, 0x28, 0x28),
        RGB(0x36, 0x36, 0x36), RGB(0x4D, 0x4D, 0x4D), RGB(0x65, 0x65, 0x65),
        RGB(0x81, 0x81, 0x81), RGB(0x9F, 0x9F, 0x9F), RGB(0xBC, 0xBC, 0xBC),
        RGB(0xE2, 0xE2, 0xE2), RGB(0xFF, 0xFF, 0xFF),
    ]

    /// Which base palette an appearance uses.
    public enum Appearance: Sendable, Hashable {
        case light
        case dark
    }

    /// The colour for an index, or `nil` for 99 and for anything out of range.
    ///
    /// `nil` means "the window's own colour", which is what 99 is defined as and the only
    /// honest answer for an index nobody defined.
    public static func colour(at index: Int, appearance: Appearance) -> RGB? {
        switch index {
        case 0..<16:
            return appearance == .light ? light[index] : dark[index]
        case 16...98:
            return extended[index - 16]
        default:
            return nil
        }
    }

    /// Resolves a foreground and background pair together.
    ///
    /// **A sender who named both named a self-consistent pair**, so both come from the
    /// literal palette whatever the window is: `^C1,0` is black on white, and it stays
    /// black on white on a dark window because the white is actually drawn behind it.
    /// Adjusting the foreground there would put light grey on white and destroy the one
    /// case the sender got unambiguously right.
    ///
    /// A foreground on its own is the case the alternate palette exists for: it lands on
    /// the window's background, which is the thing the sender could not see.
    public static func resolving(
        foreground: Int?,
        background: Int?,
        appearance: Appearance
    ) -> (foreground: RGB?, background: RGB?) {
        let table: Appearance = background == nil ? appearance : .light
        return (
            foreground.flatMap { colour(at: $0, appearance: table) },
            background.flatMap { colour(at: $0, appearance: .light) }
        )
    }
}
