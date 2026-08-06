import AppKit
import CoreText
import Testing

@testable import CaravanUI

/// The font decision, asserted rather than remembered.
///
/// `Scripts/font-coverage.swift` is what *made* the decision; this is what keeps it. The
/// failure being guarded against is silent: swap the family and every one of these still
/// renders, just 1.8 cells wide in the places that matter.
@MainActor
@Suite("Chat font")
struct ChatFontTests {
    /// The eleven characters `NSFont.monospacedSystemFont` is missing — the high-ASCII
    /// staples of BBS- and mIRC-era art, and the entire reason SF Mono is not the default.
    private static let cp437Gaps: [Character] = [
        "▬", "►", "◄", "☺", "☻", "♠", "♣", "♥", "♦", "♪", "♫",
    ]

    /// Box drawing and blocks, which any candidate has to carry outright.
    private static let boxDrawing: [Character] = ["─", "│", "┌", "┐", "└", "┘", "═", "║", "█", "▓"]

    private func hasGlyph(_ character: Character, in font: NSFont) -> Bool {
        let scalars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: scalars.count)
        let found = CTFontGetGlyphsForCharacters(font, scalars, &glyphs, scalars.count)
        return found && glyphs.allSatisfy { $0 != 0 }
    }

    @Test("the default is Menlo, not the system monospaced font")
    func defaultFamily() {
        #expect(ChatFont.defaultFamily == "Menlo")
        #expect(ChatFont.nsFont().familyName == "Menlo")
        #expect(
            ChatFont.nsFont().familyName
                != NSFont.monospacedSystemFont(
                    ofSize: 13,
                    weight: .regular
                ).familyName
        )
    }

    /// The measurement, as an assertion. Missing glyphs are not blanks — CoreText
    /// substitutes from another font, and a proportional substitute measures up to 1.80×
    /// the cell, breaking exactly the art it was asked to render.
    @Test("the chat font carries the CP437 art set the system font is missing")
    func cp437Coverage() {
        let font = ChatFont.nsFont()
        for character in Self.cp437Gaps + Self.boxDrawing {
            #expect(
                hasGlyph(character, in: font),
                "\(character) missing from \(font.familyName ?? "?")"
            )
        }
    }

    @Test("the fallback cascade is monospaced only, and is actually attached")
    func cascade() throws {
        #expect(ChatFont.fallbackFamilies == ["Andale Mono", "Courier New"])
        let attached =
            ChatFont.nsFont().fontDescriptor.fontAttributes[.cascadeList] as? [NSFontDescriptor]
        let families = try #require(attached).compactMap {
            $0.fontAttributes[.family] as? String
        }
        #expect(families == ChatFont.fallbackFamilies)

        // Every fallback must itself be monospaced, or the cascade reintroduces exactly
        // the failure it exists to prevent.
        for family in ChatFont.fallbackFamilies {
            let font = try #require(NSFont(name: family, size: 13))
            #expect(
                font.fontDescriptor.symbolicTraits.contains(.monoSpace),
                "\(family) is not monospaced"
            )
        }
    }

    /// mIRC's shape: a wrapped line continues flush-left at column 0 rather than hanging
    /// under the message column.
    @Test("wrapped lines run flush-left with no head indent")
    func noHangingIndent() {
        let style = ChatFont.paragraphStyle(for: ChatFont.nsFont())
        #expect(style.headIndent == 0)
        #expect(style.firstLineHeadIndent == 0)
        #expect(style.paragraphSpacing == 0)
        #expect(style.paragraphSpacingBefore == 0)
        #expect(style.lineBreakMode == .byWordWrapping)
    }

    /// Combining marks and Zalgo text can blow one line to hundreds of points, and this
    /// *will* be pasted into a channel.
    @Test("line height is clamped")
    func lineHeightClamp() {
        let font = ChatFont.nsFont()
        let natural = ChatFont.defaultLineHeight(for: font)
        let style = ChatFont.paragraphStyle(for: font)
        #expect(style.maximumLineHeight > natural)
        #expect(style.maximumLineHeight <= ceil(natural * ChatFont.lineHeightClamp))
    }

    /// The rule spans the width whatever the width is, which only works if it clips.
    @Test("the unread rule's style clips rather than wraps")
    func markerClips() {
        #expect(
            ChatFont.clippingParagraphStyle(for: ChatFont.nsFont()).lineBreakMode == .byClipping
        )
    }

    /// A coding font turns `!=` into `≠` and `->` into an arrow, mangling quoted code and
    /// art alike — so ligatures are off whatever the user's font does.
    @Test("ligatures are off on every rendered line")
    func ligaturesOff() {
        let controller = MessageLogController(coalesceInterval: .milliseconds(5))
        let scrollView = controller.displayView()
        controller.append([AttributedString("a != b -> c")])
        controller.flush()

        let textView = scrollView.documentView as? NSTextView
        let storage = textView?.textStorage
        let ligature = storage?.attribute(.ligature, at: 0, effectiveRange: nil) as? Int
        #expect(ligature == 0)

        let style =
            storage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle
        #expect(style?.headIndent == 0)
    }
}
