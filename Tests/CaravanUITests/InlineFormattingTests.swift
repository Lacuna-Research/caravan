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

    /// What `colour` actually draws under an appearance.
    ///
    /// A colour that differs between the two tables resolves itself at draw time — that is
    /// what lets the palette toggle repaint text already on screen — so comparing the
    /// object against a plain colour compares two different kinds of thing. This asks it
    /// what it draws.
    private func drawn(_ colour: NSColor?, in appearance: NSAppearance.Name) -> NSColor? {
        guard let colour else { return nil }
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = colour.usingColorSpace(.sRGB)
        }
        return resolved
    }

    /// The same treatment for the expected side, so both are compared in one colour space.
    private func swatch(_ colour: RGB) -> NSColor? {
        Palette.nsColor(colour).usingColorSpace(.sRGB)
    }

    private func message(from nick: String, _ text: String) -> IRCEvent {
        .message(
            target: .channel(IRCChannelName("#swift", mapping: .ascii)),
            sender: IRCSource(prefix: "\(nick)!u@h"),
            text: text,
            kind: .privmsg,
            isAction: false,
            tags: IRCTags()
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
        let colours = line.runs.map {
            (String(line[$0.range].characters), $0.appKit.foregroundColor)
        }
        let red = colours.first { $0.0 == "red" }?.1
        #expect(drawn(red, in: .darkAqua) == swatch(MIRCPalette.dark[4]))
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

    /// **The crossing into the text storage is where styling silently dies**, and it does
    /// so without an error, a warning or a failing test that merely checks the renderer's
    /// output. Two separate ways were found here at once: naming an attribute scope in the
    /// conversion drops every scope not named, and a bare `.single` writes SwiftUI's
    /// underline rather than AppKit's, which has no `NSAttributedString` key at all. So
    /// this asserts the *storage*, attribute by attribute, rather than the line.
    @Test("every kind of styling survives the crossing into the text view")
    func stylingReachesTheTextView() throws {
        let controller = MessageLogController(
            coalesceInterval: .milliseconds(1),
            palette: Palette(coloursNicks: true)
        )
        let textView = try #require(controller.displayView().documentView as? NSTextView)
        controller.append([
            renderer(palette: Palette(coloursNicks: true)).line(
                for: message(
                    from: "bob",
                    "\u{03}4red\u{03} \u{1F}under\u{1F} \u{1E}struck\u{1E} https://example.com"
                ),
                context: RenderContext()
            )!
        ])
        controller.flush()
        let storage = try #require(textView.textStorage)

        func attribute(_ key: NSAttributedString.Key, on fragment: String) throws -> Any? {
            let at = try #require(offset(of: fragment, in: storage))
            return storage.attribute(key, at: at, effectiveRange: nil)
        }

        #expect(
            drawn(try attribute(.foregroundColor, on: "red") as? NSColor, in: .darkAqua)
                == swatch(MIRCPalette.dark[4]),
            "a colour code"
        )
        #expect(try attribute(.underlineStyle, on: "under") != nil, "an underline")
        #expect(try attribute(.strikethroughStyle, on: "struck") != nil, "a strikethrough")
        #expect(try attribute(.link, on: "https://example.com") != nil, "a link")
        #expect(try attribute(.foregroundColor, on: "bob") != nil, "a nick colour")
        #expect(try attribute(.nickColumn, on: "bob") != nil, "the nick column tag")
        // And the line's own colour, which is the one that was there before this item and
        // was being dropped along with the rest.
        #expect(try attribute(.foregroundColor, on: "<") as? NSColor == LineColour.text.nsColor)
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
        let bob = colour(of: "bob", in: first)
        #expect(
            drawn(bob, in: .darkAqua)
                == NickColour.colour(for: "bob", appearance: .dark).flatMap(swatch)
        )
        // The same hue in both appearances, at the lightness that background needs.
        #expect(
            drawn(bob, in: .aqua)
                == NickColour.colour(for: "bob", appearance: .light).flatMap(swatch)
        )
        #expect(
            drawn(colour(of: "bob", in: second), in: .darkAqua) == drawn(bob, in: .darkAqua),
            "the same nick keeps its colour"
        )
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
        // The nick is still a run of its own — it carries the ``NickColumn`` that lets the
        // setting be turned back on later — but it is not a *colour* of its own, and one
        // colour across the whole line is the property worth asserting.
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
                    who: IRCSource(prefix: "bob!u@h"),
                    account: nil,
                    realName: nil
                ),
                context: RenderContext()
            )
        )
        let colours = Set(join.runs.compactMap { $0.appKit.foregroundColor })
        #expect(colours == [LineColour.event.nsColor])
    }

    /// A prefix is a fact about one channel; the colour is a fact about the person. Ops in
    /// `#a` and not in `#b` must not be two different-coloured people.
    @Test("the channel prefix is not part of what the colour is hashed on")
    func prefixDoesNotChangeTheColour() throws {
        let renderer = renderer(palette: Palette(coloursNicks: true))
        let plain = try #require(
            renderer.line(for: message(from: "bob", "hi"), context: RenderContext())
        )
        let opped = try #require(
            renderer.line(
                for: message(from: "bob", "hi"),
                context: RenderContext(senderPrefix: "@")
            )
        )
        #expect(String(opped.characters).contains("<@bob>"), "the prefix is still shown")
        #expect(
            drawn(colour(of: "@bob", in: opped), in: .darkAqua)
                == drawn(colour(of: "bob", in: plain), in: .darkAqua)
        )
    }

    /// Turning the setting off has to reach the buffer. One that applied only to the next
    /// line to arrive would leave the scrollback in two conventions at once.
    @Test("turning nick colouring off recolours lines already on screen")
    func nickColouringReachesTheBuffer() throws {
        let controller = MessageLogController(
            coalesceInterval: .milliseconds(1),
            palette: Palette(coloursNicks: true)
        )
        let textView = try #require(controller.displayView().documentView as? NSTextView)
        controller.append([
            renderer(palette: Palette(coloursNicks: true))
                .line(for: message(from: "bob", "hello"), context: RenderContext())!
        ])
        controller.flush()

        let storage = try #require(textView.textStorage)
        let nick = try #require(offset(of: "bob", in: storage))
        let coloured = storage.attribute(.foregroundColor, at: nick, effectiveRange: nil)
        #expect(
            drawn(coloured as? NSColor, in: .darkAqua)
                != drawn(LineColour.text.nsColor, in: .darkAqua)
        )

        controller.palette = Palette(coloursNicks: false)
        let plain = storage.attribute(.foregroundColor, at: nick, effectiveRange: nil)
        #expect(plain as? NSColor == LineColour.text.nsColor, "back to the line's own colour")

        controller.palette = Palette(coloursNicks: true)
        let again = storage.attribute(.foregroundColor, at: nick, effectiveRange: nil)
        #expect(
            drawn(again as? NSColor, in: .darkAqua) == drawn(coloured as? NSColor, in: .darkAqua),
            "and on again puts the same colour back"
        )
    }

    /// The other half of the toggle, and the reason indexed colours resolve themselves:
    /// pinning the mode pins the window, and every colour in it follows.
    @Test("the palette mode pins the scrollback's appearance")
    func modeReachesTheView() throws {
        let controller = MessageLogController(coalesceInterval: .milliseconds(1))
        let scrollView = controller.displayView()
        #expect(scrollView.appearance == nil, "auto leaves it to the system")

        controller.palette = Palette(mode: .dark)
        #expect(scrollView.appearance?.name == .darkAqua)
        controller.palette = Palette(mode: .light)
        #expect(scrollView.appearance?.name == .aqua)
    }

    /// `|` is a legal nick character, and `bob|away` is a shape every network is full of.
    @Test("a nick column round-trips, separator in the nick and all")
    func nickColumnRoundTrips() throws {
        for column in [
            NickColumn(nick: "bob", base: .text),
            NickColumn(nick: "bob|away", base: .ownText),
            NickColumn(nick: "|", base: .notice),
        ] {
            #expect(NickColumn(encoded: column.encoded) == column)
        }
        #expect(NickColumn(encoded: "nosuchrole|bob") == nil)
        #expect(NickColumn(encoded: "bob") == nil)
    }

    private func offset(of fragment: String, in storage: NSTextStorage) -> Int? {
        storage.string.range(of: fragment).map {
            storage.string.distance(from: storage.string.startIndex, to: $0.lowerBound)
        }
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

    /// The property the whole palette toggle rests on: one colour that answers differently
    /// depending on what is drawing it, so switching the toggle repaints the scrollback
    /// rather than only the next line to arrive.
    @Test("an index reads both tables and lets the window pick")
    func indexFollowsTheDrawingAppearance() {
        let colour = Palette().colours(foreground: .indexed(2), background: nil).foreground
        #expect(drawn(colour, in: .aqua) == swatch(MIRCPalette.light[2]))
        #expect(drawn(colour, in: .darkAqua) == swatch(MIRCPalette.dark[2]))
    }

    /// And the other half: which appearance draws is what the mode decides.
    @Test("the mode pins the window's appearance, and auto leaves it alone")
    func modePinsTheAppearance() {
        #expect(Palette.Mode.auto.nsAppearance == nil)
        #expect(Palette.Mode.light.nsAppearance?.name == .aqua)
        #expect(Palette.Mode.dark.nsAppearance?.name == .darkAqua)
    }

    /// The fixed 16–98 range is one table, not two, so it needs no resolving at all.
    @Test("an extended index is the same colour in both appearances")
    func extendedIndexIsPlain() {
        let colour = Palette().colours(foreground: .indexed(40), background: nil).foreground
        #expect(colour == Palette.nsColor(MIRCPalette.extended[40 - 16]))
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
