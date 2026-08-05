import AppKit
import CoreText

// Ranges that matter for IRC ASCII/ANSI art and general chat rendering.
struct Range2 { let name: String; let lo: UInt32; let hi: UInt32 }

let ranges: [Range2] = [
    Range2(name: "Latin-1 Supplement  U+00A0-00FF", lo: 0x00A0, hi: 0x00FF),
    Range2(name: "Arrows              U+2190-21FF", lo: 0x2190, hi: 0x21FF),
    Range2(name: "Box Drawing         U+2500-257F", lo: 0x2500, hi: 0x257F),
    Range2(name: "Block Elements      U+2580-259F", lo: 0x2580, hi: 0x259F),
    Range2(name: "Geometric Shapes    U+25A0-25FF", lo: 0x25A0, hi: 0x25FF),
    Range2(name: "Misc Symbols        U+2600-26FF", lo: 0x2600, hi: 0x26FF),
    Range2(name: "Braille Patterns    U+2800-28FF", lo: 0x2800, hi: 0x28FF),
]

// The classic CP437 / ANSI-art working set. These are the characters that
// actually appear in BBS and mIRC-era art.
let cp437Art: [UInt32] = [
    0x2591, 0x2592, 0x2593, 0x2588,                 // shade + full block
    0x2580, 0x2584, 0x258C, 0x2590,                 // half blocks
    0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, // single box
    0x251C, 0x2524, 0x252C, 0x2534, 0x253C,
    0x2550, 0x2551, 0x2554, 0x2557, 0x255A, 0x255D, // double box
    0x2560, 0x2563, 0x2566, 0x2569, 0x256C,
    0x25A0, 0x25AC, 0x25B2, 0x25BA, 0x25C4, 0x25CB, // geometric
    0x263A, 0x263B, 0x2660, 0x2663, 0x2665, 0x2666, // faces + suits
    0x266A, 0x266B,                                 // notes
]

// Width-ambiguous characters: present in nearly every font, but East Asian
// Ambiguous, so renderers disagree about whether they occupy one cell or two.
let ambiguous: [(UInt32, String)] = [
    (0x00B7, "MIDDLE DOT"),
    (0x2022, "BULLET"),
    (0x00A7, "SECTION SIGN"),
    (0x00B1, "PLUS-MINUS"),
    (0x00D7, "MULTIPLICATION"),
    (0x2018, "LEFT SINGLE QUOTE"),
    (0x2026, "HORIZONTAL ELLIPSIS"),
    (0x2500, "BOX LIGHT HORIZONTAL"),
    (0x2588, "FULL BLOCK"),
    (0x25CB, "WHITE CIRCLE"),
    (0x2665, "BLACK HEART"),
]

let size: CGFloat = 13.0

func makeFont(_ name: String) -> CTFont? {
    let f = CTFontCreateWithName(name as CFString, size, nil)
    let actual = CTFontCopyPostScriptName(f) as String
    // CoreText silently substitutes a fallback when the name is unknown.
    guard actual.caseInsensitiveCompare(name) == .orderedSame else { return nil }
    return f
}

func glyphs(_ font: CTFont, _ scalars: [UInt32]) -> [(UInt32, CGGlyph)] {
    var utf16: [UniChar] = []
    var index: [Int] = []   // maps utf16 position -> scalar index
    for (i, s) in scalars.enumerated() {
        for u in Unicode.Scalar(s)!.utf16 { utf16.append(u); index.append(i) }
    }
    var gs = [CGGlyph](repeating: 0, count: utf16.count)
    _ = CTFontGetGlyphsForCharacters(font, utf16, &gs, utf16.count)
    var out: [(UInt32, CGGlyph)] = []
    for (i, s) in scalars.enumerated() {
        let pos = index.firstIndex(of: i)!
        out.append((s, gs[pos]))
    }
    return out
}

func advance(_ font: CTFont, _ g: CGGlyph) -> CGFloat {
    var glyph = g
    var adv = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &adv, 1)
    return adv.width
}

func cellWidth(_ font: CTFont) -> CGFloat {
    let g = glyphs(font, [0x30])[0].1     // "0"
    return advance(font, g)
}

func isMonospaced(_ font: CTFont) -> Bool {
    let traits = CTFontGetSymbolicTraits(font)
    return traits.contains(.traitMonoSpace)
}

// Candidate fonts. The API-derived one first, since that is the proposed default.
let apiFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
let apiName = (CTFontCopyPostScriptName(apiFont as CTFont) as String)

var candidates: [(String, CTFont)] = [("\(apiName)  [monospacedSystemFont API]", apiFont as CTFont)]
for name in ["Menlo-Regular", "Monaco", "AndaleMono", "Courier", "PTMono-Regular",
             "SFMono-Regular", "CourierNewPSMT", "HelveticaNeue"] {
    if let f = makeFont(name) { candidates.append((name, f)) }
}

print("Cell size \(size)pt\n")
print(String(repeating: "=", count: 78))

for (name, font) in candidates {
    let cell = cellWidth(font)
    print("\n\(name)")
    print("  monospace trait: \(isMonospaced(font) ? "yes" : "NO")   cell width: \(String(format: "%.3f", cell))")

    for r in ranges {
        let scalars = Array(r.lo...r.hi).filter { Unicode.Scalar($0) != nil }
        let gs = glyphs(font, scalars)
        let present = gs.filter { $0.1 != 0 }
        let offGrid = present.filter { abs(advance(font, $0.1) - cell) > 0.01 }
        let pct = Int((Double(present.count) / Double(scalars.count)) * 100)
        var line = "  \(r.name): \(present.count)/\(scalars.count) (\(pct)%)"
        if !offGrid.isEmpty {
            line += "   OFF-GRID: \(offGrid.count)"
        }
        print(line)
    }

    let art = glyphs(font, cp437Art)
    let artMissing = art.filter { $0.1 == 0 }
    let artOffGrid = art.filter { $0.1 != 0 && abs(advance(font, $0.1) - cell) > 0.01 }
    print("  CP437 ANSI-art set: \(cp437Art.count - artMissing.count)/\(cp437Art.count) present", terminator: "")
    if !artMissing.isEmpty {
        let list = artMissing.map { String(format: "U+%04X", $0.0) }.joined(separator: " ")
        print("   MISSING: \(list)", terminator: "")
    }
    if !artOffGrid.isEmpty {
        let list = artOffGrid.map {
            String(format: "U+%04X(%.2fx)", $0.0, advance(font, $0.1) / cell)
        }.joined(separator: " ")
        print("   OFF-GRID: \(list)", terminator: "")
    }
    print("")

    var ambNotes: [String] = []
    for (s, label) in ambiguous {
        let g = glyphs(font, [s])[0].1
        if g == 0 { ambNotes.append("\(label) MISSING"); continue }
        let ratio = advance(font, g) / cell
        if abs(ratio - 1.0) > 0.01 {
            ambNotes.append(String(format: "%@ %.2fx", label, ratio))
        }
    }
    print("  width-ambiguous chars off-grid: \(ambNotes.isEmpty ? "none" : ambNotes.joined(separator: ", "))")
}
print("\n" + String(repeating: "=", count: 78))
