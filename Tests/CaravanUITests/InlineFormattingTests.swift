import AppKit
import IRCFormat
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// Formatting codes as they reach the buffer: parsed out of the text, laid back over the
/// stretch of the line the text became, and never left as control characters.
@MainActor
@Suite("Inline formatting in lines")
struct InlineFormattingTests {
    private func renderer(
        palette: Palette = Palette(mode: .dark, coloursNicks: false)
    ) -> LineRenderer {
        LineRenderer(timestampFormat: "", palette: palette)
    }

    /// The colour of the run holding `fragment`. Looked up by content rather than by run
    /// index, because `<bob>` is three runs and which one is the nick is the test's least
    /// interesting detail.
    private func colour(of fragment: String, in line: AttributedString) -> NSColor? {
        line.runs.first { String(line[$0.range].characters) == fragment }?.appKit.foregroundColor
    }

    private func message(from nick: String, _ text: String) -> IRCEvent {
        .message(
            target: .channel(IRCChannelName("#swift", mapping: .ascii)),
            sender: IRCSource(prefix: "\(nick)!u@h"),
            text: text,
            kind: .privmsg,
            isAction: false
        )
    }

    /// The one thing that must never happen: a control character reaching the buffer,
    /// where it renders as a control picture in the middle of somebody's sentence.
    @Test("no control character survives into the line")
    func codesAreStripped() {
        let line = renderer().line(
            for: message(from: "bob", "\u{02}bold\u{02} and \u{03}4red\u{0F} done"),
            context: RenderContext()
        )
        let text = line.map { String($0.characters) } ?? ""
        #expect(text == "<bob> bold and red done")
        #expect(!text.contains { IRCFormatting.allCodes.contains($0) })
    }

    @Test("a colour code paints only the run it opened")
    func colourAppliesToItsRun() throws {
        let line = try #require(
            renderer().line(
                for: message(from: "bob", "plain \u{03}4red\u{03} plain"),
                context: RenderContext()
            )
        )
        let red = Palette.nsColor(MIRCPalette.dark[4])
        let colours = line.runs.map {
            (String(line[$0.range].characters), $0.appKit.foregroundColor)
        }
        #expect(colours.contains { $0.0 == "red" && $0.1 == red })
        #expect(colours.contains { $0.0.contains("plain") && $0.1 != red })
    }

    /// Bold cannot be a font in an `AttributedString` under Swift 6, so it travels as a
    /// trait. If this stops being set, bold silently stops existing.
    @Test("bold and italic survive as traits")
    func traitsAreCarried() throws {
        let line = try #require(
            renderer().line(
                for: message(from: "bob", "\u{02}b\u{02}\u{1D}i\u{1D}"),
                context: RenderContext()
            )
        )
        let traits = line.runs.map { (String(line[$0.range].characters), $0.inlineTraits) }
        #expect(traits.contains { $0.0 == "b" && $0.1 == .bold })
        #expect(traits.contains { $0.0 == "i" && $0.1 == .italic })
    }

    /// The traits have to survive the conversion into the text storage as well, which is
    /// why the attribute is Objective-C convertible — a Swift-only one is dropped there.
    @Test("traits reach the text view as a real bold font")
    func traitsReachTheTextView() throws {
        let controller = MessageLogController(coalesceInterval: .milliseconds(1))
        let textView = try #require(controller.displayView().documentView as? NSTextView)
        controller.append([
            renderer().line(
                for: message(from: "bob", "\u{02}loud\u{02} quiet"),
                context: RenderContext()
            )!
        ])
        controller.flush()

        let storage = try #require(textView.textStorage)
        let loud = try #require(storage.string.range(of: "loud"))
        let offset = storage.string.distance(from: storage.string.startIndex, to: loud.lowerBound)
        let font = storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)

        let quiet = try #require(storage.string.range(of: "quiet"))
        let quietOffset = storage.string.distance(
            from: storage.string.startIndex,
            to: quiet.lowerBound
        )
        let plain = storage.attribute(.font, at: quietOffset, effectiveRange: nil) as? NSFont
        #expect(plain?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    /// The carry-forward this item was handed: a font change used to flatten every styled
    /// run in the buffer.
    @Test("changing the font keeps bold bold")
    func restylePreservesTraits() throws {
        let controller = MessageLogController(coalesceInterval: .milliseconds(1))
        let textView = try #require(controller.displayView().documentView as? NSTextView)
        controller.append([
            renderer().line(
                for: message(from: "bob", "\u{02}loud\u{02}"),
                context: RenderContext()
            )!
        ])
        controller.flush()
        controller.chatFont = ChatFont.nsFont(family: "Menlo", size: 18)

        let storage = try #require(textView.textStorage)
        let loud = try #require(storage.string.range(of: "loud"))
        let offset = storage.string.distance(from: storage.string.startIndex, to: loud.lowerBound)
        let font = try #require(
            storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
        )
        #expect(font.pointSize == 18, "the new size must apply")
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold), "and the bold must survive it")
    }

    // MARK: - Nick colours

    @Test("a nick is coloured, and the same nick keeps its colour")
    func nickColours() throws {
        let renderer = renderer(palette: Palette(mode: .dark, coloursNicks: true))
        let first = try #require(
            renderer.line(for: message(from: "bob", "one"), context: RenderContext())
        )
        let second = try #require(
            renderer.line(for: message(from: "bob", "two"), context: RenderContext())
        )
        let expected = NickColour.colour(for: "bob", appearance: .dark).map(Palette.nsColor)
        #expect(colour(of: "bob", in: first) == expected)
        #expect(colour(of: "bob", in: second) == expected)
        // The angle brackets are the line's colour, not the nick's: only the name is
        // coloured, or the column stops reading as a column.
        #expect(colour(of: "<", in: first) == LineColour.text.nsColor)
    }

    @Test("nick colouring can be turned off")
    func nickColoursOff() throws {
        let line = try #require(
            renderer(palette: Palette(mode: .dark, coloursNicks: false))
                .line(for: message(from: "bob", "hello"), context: RenderContext())
        )
        // With colouring off the nick is not a run of its own at all: the whole line is
        // one colour, which is the property worth asserting.
        #expect(
            Set(line.runs.compactMap { $0.appKit.foregroundColor }) == [LineColour.text.nsColor]
        )
    }

    /// Colouring names inside an event sentence turns the event stream into a ransom note.
    @Test("only lines with a nick column colour their nick")
    func onlyNickColumns() throws {
        let renderer = renderer(palette: Palette(mode: .dark, coloursNicks: true))
        let join = try #require(
            renderer.line(
                for: .joined(
                    channel: IRCChannelName("#swift", mapping: .ascii),
                    who: IRCSource(prefix: "bob!u@h")
                ),
                context: RenderContext()
            )
        )
        let colours = Set(join.runs.compactMap { $0.appKit.foregroundColor })
        #expect(colours == [LineColour.event.nsColor])
    }

    /// A manual override is the escape hatch §6 asks for.
    @Test("a per-nick override wins over the hash")
    func nickOverride() throws {
        let palette = Palette(
            mode: .dark,
            coloursNicks: true,
            nickOverrides: ["bob": RGB(0x12, 0x34, 0x56)]
        )
        let line = try #require(
            renderer(palette: palette).line(
                for: message(from: "bob", "hi"),
                context: RenderContext()
            )
        )
        #expect(colour(of: "bob", in: line) == Palette.nsColor(RGB(0x12, 0x34, 0x56)))
    }

    // MARK: - Palette resolution

    @Test("the mode picks which base table an index reads")
    func modePicksTheTable() {
        let dark = Palette(mode: .dark).colours(foreground: .indexed(2), background: nil)
        let light = Palette(mode: .light).colours(foreground: .indexed(2), background: nil)
        #expect(dark.foreground == Palette.nsColor(MIRCPalette.dark[2]))
        #expect(light.foreground == Palette.nsColor(MIRCPalette.light[2]))
    }

    @Test("auto follows the appearance it is handed")
    func autoFollowsTheSystem() {
        let inDark = Palette(mode: .auto, systemAppearance: .dark)
        let inLight = Palette(mode: .auto, systemAppearance: .light)
        #expect(inDark.appearance == .dark)
        #expect(inLight.appearance == .light)
    }

    @Test("a per-index override replaces the table entry")
    func indexOverride() {
        let palette = Palette(mode: .dark, overrides: [4: RGB(0x00, 0x11, 0x22)])
        #expect(
            palette.colours(foreground: .indexed(4), background: nil).foreground
                == Palette.nsColor(RGB(0x00, 0x11, 0x22))
        )
    }

    /// A hex colour is the sender naming an exact value, so no table and no override
    /// applies — second-guessing it overrules the one thing they were explicit about.
    @Test("a hex colour is used exactly as sent")
    func hexIsLiteral() {
        let palette = Palette(mode: .dark, overrides: [4: RGB(0x00, 0x11, 0x22)])
        #expect(
            palette.colours(foreground: .hex(RGB(0xAB, 0xCD, 0xEF)), background: nil).foreground
                == Palette.nsColor(RGB(0xAB, 0xCD, 0xEF))
        )
    }

    @Test("index 99 leaves the window's own colour alone")
    func defaultIndexPaintsNothing() {
        let resolved = Palette(mode: .dark).colours(foreground: .indexed(99), background: nil)
        #expect(resolved.foreground == nil)
        #expect(resolved.background == nil)
    }
}
