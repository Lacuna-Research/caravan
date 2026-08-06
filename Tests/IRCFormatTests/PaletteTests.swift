import Testing

@testable import IRCFormat

/// The palettes, and the contrast rules that are the whole reason there are two of them.
@Suite("Palettes")
struct PaletteTests {
    @Test("the tables are the sizes the specification gives")
    func tableSizes() {
        #expect(MIRCPalette.light.count == 16)
        #expect(MIRCPalette.dark.count == 16)
        #expect(MIRCPalette.extended.count == 83)  // 16...98
    }

    /// Spot-checks against <https://modern.ircdocs.horse/formatting>, at both ends and
    /// across a boundary. The whole table is transcribed; these are the ones that catch an
    /// off-by-one in the index arithmetic.
    @Test("extended indices land on the specified values")
    func extendedValues() {
        #expect(MIRCPalette.colour(at: 16, appearance: .light) == RGB(0x47, 0x00, 0x00))
        #expect(MIRCPalette.colour(at: 52, appearance: .light) == RGB(0xFF, 0x00, 0x00))
        #expect(MIRCPalette.colour(at: 88, appearance: .light) == RGB(0x00, 0x00, 0x00))
        #expect(MIRCPalette.colour(at: 98, appearance: .light) == RGB(0xFF, 0xFF, 0xFF))
    }

    @Test("the extended range does not change with the appearance")
    func extendedIsFixed() {
        for index in 16...98 {
            #expect(
                MIRCPalette.colour(at: index, appearance: .light)
                    == MIRCPalette.colour(at: index, appearance: .dark)
            )
        }
    }

    /// 99 is defined as the window's own colour, and an index nobody defined has no
    /// honest answer either.
    @Test("99 and out-of-range mean the window's own colour")
    func defaultIndex() {
        #expect(MIRCPalette.colour(at: 99, appearance: .light) == nil)
        #expect(MIRCPalette.colour(at: 100, appearance: .light) == nil)
        #expect(MIRCPalette.colour(at: -1, appearance: .light) == nil)
    }

    /// §5's requirement, as a property — but only for the table that is *ours*.
    ///
    /// The light table is mIRC's own sixteen and is deliberately left literal: yellow on
    /// white genuinely is unreadable in mIRC too, and silently darkening a sender's yellow
    /// would be inventing a colour they did not ask for. The dark table is the one this
    /// project designed, so it is the one that has to answer for itself.
    @Test("every entry in the dark table is legible on a dark window")
    func darkTableIsLegible() {
        for (index, colour) in MIRCPalette.dark.enumerated() {
            let ratio = colour.contrastRatio(against: NickColour.darkBackground)
            #expect(ratio >= 3.0, "dark palette index \(index) is illegible: \(ratio)")
        }
    }

    /// The light table is mIRC's, transcribed rather than improved.
    @Test("the light table is mIRC's own values, left alone")
    func lightTableIsLiteral() {
        #expect(MIRCPalette.light[0] == RGB(0xFF, 0xFF, 0xFF))
        #expect(MIRCPalette.light[1] == RGB(0x00, 0x00, 0x00))
        #expect(MIRCPalette.light[4] == RGB(0xFF, 0x00, 0x00))
    }

    /// The pair rule. A sender who named both named a self-consistent pair, and adjusting
    /// the foreground would destroy the one case they got unambiguously right.
    @Test("an explicit background makes both colours literal")
    func explicitBackgroundIsLiteral() {
        let (foreground, background) = MIRCPalette.resolving(
            foreground: 1,
            background: 0,
            appearance: .dark
        )
        #expect(foreground == MIRCPalette.light[1], "black on white must stay black on white")
        #expect(background == MIRCPalette.light[0])
    }

    @Test("a foreground on its own is adjusted for the window")
    func loneForegroundIsAdjusted() {
        let (dark, _) = MIRCPalette.resolving(foreground: 1, background: nil, appearance: .dark)
        let (light, _) = MIRCPalette.resolving(foreground: 1, background: nil, appearance: .light)
        #expect(dark == MIRCPalette.dark[1])
        #expect(light == MIRCPalette.light[1])
        #expect(dark != light, "the alternate palette exists precisely for this case")
    }
}

/// §6: hash-based nick colours, and the contrast check that keeps one palette serving
/// both appearances.
@Suite("Nick colours")
struct NickColourTests {
    /// The requirement that made §6 say "not a naive hue wheel".
    @Test("every entry clears the floor on the background it is drawn on")
    func paletteClearsItsBackground() {
        for appearance in [MIRCPalette.Appearance.light, .dark] {
            let background = NickColour.background(for: appearance)
            for (index, colour) in NickColour.palette(for: appearance).enumerated() {
                let ratio = colour.contrastRatio(against: background)
                #expect(
                    ratio >= NickColour.contrastFloor,
                    "nick palette \(index) on \(appearance) is \(ratio)"
                )
            }
        }
    }

    /// Why there are two palettes at all: no single colour can clear 4.5:1 against both
    /// near-white and near-black. Asserted rather than left in a comment, because it is
    /// the entire justification for the hue-plus-lightness split, and a future reader will
    /// otherwise try to collapse them back into one table.
    @Test("no single colour could have served both backgrounds")
    func oneTableWasImpossible() {
        let best =
            (0...255).map { value -> Double in
                let grey = RGB(UInt8(value), UInt8(value), UInt8(value))
                return min(
                    grey.contrastRatio(against: NickColour.lightBackground),
                    grey.contrastRatio(against: NickColour.darkBackground)
                )
            }.max() ?? 0
        #expect(best < NickColour.contrastFloor)
    }

    /// The hash's answer has to mean the same hue in both tables, or a nick changes
    /// identity when the theme does.
    @Test("the two palettes line up")
    func huesLineUp() {
        #expect(NickColour.lightPalette.count == NickColour.darkPalette.count)
        #expect(!NickColour.lightPalette.isEmpty)
    }

    /// A colour that changed when you restarted would be worse than no colour at all,
    /// which is why the hash is written out rather than taken from `Hasher`.
    @Test("the hash is a fixed function of the nick")
    func hashIsStable() {
        // Pinned to the value FNV-1a actually produces, so a "harmless" change to the
        // hash shows up as a failing test rather than as everyone's colours moving.
        #expect(NickColour.hash(of: "bob") == 21_748_447_695_211_092)
    }

    /// Seeded on the nick alone, and folded, so one person wears one colour however they
    /// capitalise it and whichever network you reach them on.
    @Test("case does not change a nick's colour")
    func caseInsensitive() {
        for appearance in [MIRCPalette.Appearance.light, .dark] {
            let expected = NickColour.colour(for: "bob", appearance: appearance)
            #expect(NickColour.colour(for: "Bob", appearance: appearance) == expected)
            #expect(NickColour.colour(for: "BOB", appearance: appearance) == expected)
        }
    }

    @Test("different nicks generally get different colours")
    func spread() {
        let nicks = ["alice", "bob", "carol", "dave", "erin", "frank", "grace"]
        let colours = Set(nicks.compactMap { NickColour.colour(for: $0, appearance: .light) })
        #expect(colours.count >= 5, "a hash that clusters this hard is not spreading")
    }

    @Test("an index is always inside the palette")
    func indexInRange() {
        for nick in ["a", "zzzzzzzz", "", "\u{1F600}", "nick[]\\"] {
            let index = NickColour.index(for: nick, count: NickColour.lightPalette.count)
            #expect((0..<NickColour.lightPalette.count).contains(index))
        }
    }
}
