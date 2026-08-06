/// Per-nick colours, chosen by hash (GUI-DESIGN-NOTES.md §6).
///
/// **Seeded on the nick alone**, not nick plus network, so `bob` looks like `bob` whether
/// you reach him directly or through a bouncer. The hash is written out here rather than
/// taken from `Hasher`, which is seeded per process — the same nick would get a different
/// colour on every launch, and a colour that changes when you restart is worse than no
/// colour at all.
///
/// **One hue per nick, two lightnesses.** §6 asks for the palette to be contrast-checked
/// against both backgrounds, and the arithmetic says a single colour cannot clear the AA
/// floor on both: legibility on white needs relative luminance at most 0.183, legibility
/// on near-black needs at least 0.234, and the best any one colour can do against both at
/// once is about 4.08:1. So the hash picks a *hue*, and the appearance picks how light
/// that hue is drawn. A nick keeps its identity across a theme switch — bob is still the
/// blue one — and both variants clear 4.5:1 properly rather than nearly.
public enum NickColour {
    /// Which background a palette is drawn against.
    public typealias Appearance = MIRCPalette.Appearance

    /// Hues for a light window: dark and saturated, every one AA on white.
    public static let lightPalette: [RGB] = [
        RGB(0xB9, 0x1C, 0x1C),  // red
        RGB(0xC2, 0x41, 0x0C),  // orange
        RGB(0xA1, 0x62, 0x07),  // amber
        RGB(0x4D, 0x7C, 0x0F),  // lime
        RGB(0x15, 0x80, 0x3D),  // green
        RGB(0x04, 0x78, 0x57),  // emerald
        RGB(0x0F, 0x76, 0x6E),  // teal
        RGB(0x0E, 0x74, 0x90),  // cyan
        RGB(0x1D, 0x4E, 0xD8),  // blue
        RGB(0x43, 0x38, 0xCA),  // indigo
        RGB(0x6D, 0x28, 0xD9),  // violet
        RGB(0x7E, 0x22, 0xCE),  // purple
        RGB(0xA2, 0x1C, 0xAF),  // fuchsia
        RGB(0xBE, 0x18, 0x5D),  // pink
    ]

    /// The same hues for a dark window: light and desaturated, every one AA on near-black.
    ///
    /// Same order, same length — that is what makes the hash's answer mean the same thing
    /// in both, and ``huesLineUp`` is the test that keeps it so.
    public static let darkPalette: [RGB] = [
        RGB(0xFC, 0xA5, 0xA5),  // red
        RGB(0xFD, 0xBA, 0x74),  // orange
        RGB(0xFC, 0xD3, 0x4D),  // amber
        RGB(0xBE, 0xF2, 0x64),  // lime
        RGB(0x86, 0xEF, 0xAC),  // green
        RGB(0x6E, 0xE7, 0xB7),  // emerald
        RGB(0x5E, 0xEA, 0xD4),  // teal
        RGB(0x67, 0xE8, 0xF9),  // cyan
        RGB(0x93, 0xC5, 0xFD),  // blue
        RGB(0xA5, 0xB4, 0xFC),  // indigo
        RGB(0xC4, 0xB5, 0xFD),  // violet
        RGB(0xD8, 0xB4, 0xFE),  // purple
        RGB(0xF0, 0xAB, 0xFC),  // fuchsia
        RGB(0xF9, 0xA8, 0xD4),  // pink
    ]

    /// The WCAG ratio every entry must clear against the background it is drawn on.
    ///
    /// 4.5:1 is the AA floor for body text, and chat *is* body text. Deliberately not the
    /// 3:1 large-text allowance: a nick renders at the same size as everything else.
    public static let contrastFloor = 4.5

    /// The backgrounds the palettes are checked against.
    ///
    /// Not pure white and pure black — the windows are not those. Near-black is what macOS
    /// actually draws in dark mode, and checking against the extreme would pass entries
    /// that fail in the app.
    public static let lightBackground = RGB(0xFF, 0xFF, 0xFF)
    public static let darkBackground = RGB(0x1E, 0x1E, 0x1E)

    public static func palette(for appearance: Appearance) -> [RGB] {
        appearance == .light ? lightPalette : darkPalette
    }

    public static func background(for appearance: Appearance) -> RGB {
        appearance == .light ? lightBackground : darkBackground
    }

    /// The colour for a nick on a given background.
    ///
    /// Folded before hashing, so `Bob` and `bob` are one person wearing one colour. The
    /// fold is ASCII-only on purpose: this is a display choice, and reaching for the
    /// server's casemapping would make a nick change colour when it moves network — which
    /// is exactly what seeding on the nick alone exists to prevent.
    public static func colour(for nick: some StringProtocol, appearance: Appearance) -> RGB? {
        let palette = palette(for: appearance)
        guard !palette.isEmpty else { return nil }
        return palette[index(for: nick, count: palette.count)]
    }

    /// The palette index for a nick. Exposed so a test can assert stability directly.
    public static func index(for nick: some StringProtocol, count: Int) -> Int {
        precondition(count > 0, "a palette needs at least one colour")
        return Int(hash(of: nick) % UInt64(count))
    }

    /// FNV-1a, 64-bit. Chosen for being short, stable and specified — the properties that
    /// matter here are "same answer forever" and "spreads adjacent nicks apart", not
    /// cryptographic ones.
    public static func hash(of nick: some StringProtocol) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in nick.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}
