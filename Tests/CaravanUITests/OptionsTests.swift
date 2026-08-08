import AppKit
import Foundation
import IRCFormat
import Testing

@testable import CaravanUI

/// The two properties every Options control has to keep.
///
/// Not a test of the views — a `Form` is not the interesting part. The interesting part is
/// that a control's change reaches `caravan.conf` immediately and that the file a user has
/// edited by hand comes back intact, and both of those are assertions about the model and
/// the file rather than about pixels.
@MainActor
@Suite("Options")
struct OptionsTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "caravan-options-\(UUID().uuidString)")
            .appending(path: "caravan.conf")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    /// **The requirement the whole surface rests on.** A settings pane that rewrote the
    /// file would eat the user's comments, and they would only find out later.
    @Test("a hand-edited file survives every control being changed")
    func handEditedFileSurvives() throws {
        let url = temporaryFile()
        try write(
            """
            # My settings. Do not lose this comment.
            chat.font-size = 15

            ; a second comment style
            something.unknown = kept
            chat.timestamp-format = [HH:mm]
            """,
            to: url
        )

        let settings = ChatSettings(config: ConfigFile(url: url))
        #expect(settings.fontSize == 15)
        #expect(settings.timestampFormat == "[HH:mm]")

        // Every scalar control on every tab.
        settings.fontFamily = "Andale Mono"
        settings.fontSize = 14
        settings.density = .comfortable
        settings.zoom = 1.2
        settings.timestampFormat = "[HH:mm:ss]"
        settings.scrollbackLines = 2000
        settings.showsRawTraffic = true
        settings.paletteMode = .dark
        settings.coloursNicks = false
        settings.completionSuffix = CompletionStyle(atLineStart: "> ", elsewhere: " ")
        settings.colourOverrides = [4: RGB(0x11, 0x22, 0x33)]

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# My settings. Do not lose this comment."))
        #expect(text.contains("; a second comment style"))
        #expect(text.contains("something.unknown = kept"))
        // The blank line between the comment and the unknown key is structure the user
        // put there, and rewriting the file wholesale is exactly how it would be lost.
        #expect(text.contains("\n\n"))
        // Changed in place rather than appended twice.
        #expect(text.components(separatedBy: "chat.font-size").count - 1 == 1)
        #expect(text.contains("chat.font-size = 14"))
    }

    /// Write-through, in the only sense that matters: a second reader started afterwards
    /// sees it. There is no Apply button to press, so if this fails nothing would save.
    @Test("a change is on disk before anything else happens")
    func writesThrough() throws {
        let url = temporaryFile()
        let settings = ChatSettings(config: ConfigFile(url: url))

        settings.density = .compact
        settings.zoom = 1.5
        settings.colourOverrides = [0: RGB(0xAB, 0xCD, 0xEF)]

        let reread = ChatSettings(config: ConfigFile(url: url))
        #expect(reread.density == .compact)
        #expect(reread.zoom == 1.5)
        #expect(reread.colourOverrides[0] == RGB(0xAB, 0xCD, 0xEF))
    }

    // MARK: - Colours

    @Test("a colour override is one key per index, and absent when cleared")
    func colourOverridesAreOneKeyEach() throws {
        let url = temporaryFile()
        let settings = ChatSettings(config: ConfigFile(url: url))

        settings.colourOverrides = [4: RGB(0xFF, 0x00, 0x00), 12: RGB(0x00, 0x00, 0xFF)]
        var text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("chat.colour.4 = FF0000"))
        #expect(text.contains("chat.colour.12 = 0000FF"))
        // Indices nobody touched are not written out with their defaults.
        #expect(!text.contains("chat.colour.5"))

        settings.colourOverrides[4] = nil
        text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("chat.colour.4"))
        #expect(text.contains("chat.colour.12 = 0000FF"))
    }

    /// This file is hand-edited, so a typo should cost the one colour rather than the
    /// launch — the same rule `chat.palette = darkk` already follows.
    @Test("a nonsense colour line is skipped, not fatal")
    func badColourLinesAreSkipped() throws {
        let url = temporaryFile()
        try write(
            """
            chat.colour.4 = FF0000
            chat.colour.5 = nonsense
            chat.colour.99 = 00FF00
            chat.colour.mauve = 00FF00
            """,
            to: url
        )
        let settings = ChatSettings(config: ConfigFile(url: url))
        #expect(settings.colourOverrides == [4: RGB(0xFF, 0x00, 0x00)])
    }

    /// A key the app owns must be clearable even when the app never wrote it — otherwise
    /// a hand-added override could not be removed from the UI that owns it.
    @Test("a hand-added override is cleared by the grid, not orphaned")
    func handAddedOverrideIsClearable() throws {
        let url = temporaryFile()
        try write("chat.colour.7 = 123456\n", to: url)
        let settings = ChatSettings(config: ConfigFile(url: url))
        #expect(settings.colourOverrides[7] == RGB(0x12, 0x34, 0x56))

        settings.colourOverrides = [:]
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("chat.colour.7"))
    }

    @Test("an override reaches the palette a line is drawn with")
    func overrideReachesThePalette() {
        let settings = ChatSettings(config: ConfigFile(url: temporaryFile()))
        let before = settings.palette.swatch(at: 4)
        settings.colourOverrides = [4: RGB(0x12, 0x34, 0x56)]
        let after = settings.palette.swatch(at: 4)

        #expect(before != after)
        #expect(after.usingColorSpace(.sRGB)?.redComponent ?? 0 == 0x12 / 255.0)
        // Untouched indices still answer with the table's own value.
        #expect(settings.palette.swatch(at: 5) == Palette().swatch(at: 5))
    }

    @Test("only 0 to 15 may be overridden")
    func onlyTheSixteenAreOverridable() {
        #expect(ChatSettings.overridableColours.count == 16)
        #expect(!ChatSettings.overridableColours.contains(16))
        // The extended range still resolves — it is fixed, not absent.
        #expect(Palette().swatch(at: 50) != Palette().swatch(at: 51))
    }

    // MARK: - Density and zoom

    /// §15.6: a requested size is never clamped downward. Compact is the font's natural
    /// height, so no preset can make a line shorter than its glyphs need.
    @Test("density opens lines up and never shrinks them below natural")
    func densityNeverShrinksBelowNatural() {
        let font = ChatFont.nsFont()
        let natural = ChatFont.defaultLineHeight(for: font)

        let compact = ChatFont.paragraphStyle(for: font, density: .compact)
        let normal = ChatFont.paragraphStyle(for: font, density: .normal)
        let comfortable = ChatFont.paragraphStyle(for: font, density: .comfortable)

        #expect(compact.minimumLineHeight >= natural)
        #expect(normal.minimumLineHeight > compact.minimumLineHeight)
        #expect(comfortable.minimumLineHeight > normal.minimumLineHeight)
        // A maximum below the minimum is a paragraph style that draws nothing.
        for style in [compact, normal, comfortable] {
            #expect(style.maximumLineHeight >= style.minimumLineHeight)
        }
        // Zero paragraph spacing between messages stays the default (§15.5).
        #expect(normal.paragraphSpacing == 0)
        #expect(normal.paragraphSpacingBefore == 0)
    }

    /// Density is line height, *not* point size — the claim §15.5 makes by name.
    @Test("density does not touch the font size")
    func densityIsNotSize() {
        let settings = ChatSettings(config: ConfigFile(url: temporaryFile()))
        let before = settings.effectiveFontSize
        settings.density = .comfortable
        #expect(settings.effectiveFontSize == before)
    }

    @Test("zoom scales the font and returns exactly to actual size")
    func zoomIsReversible() {
        let model = temporaryModel()
        let settings = model.settings
        let base = settings.effectiveFontSize

        model.zoomIn()
        #expect(settings.effectiveFontSize > base)
        model.zoomOut()
        // Multiplicative steps, so out-and-back is exact rather than nearly.
        #expect(settings.zoom == 1.0)
        #expect(settings.effectiveFontSize == base)

        model.zoomIn()
        model.zoomIn()
        model.resetZoom()
        #expect(settings.zoom == ChatSettings.Default.zoom)
        #expect(settings.effectiveFontSize == base)
    }

    @Test("zoom stops at the ends of its range")
    func zoomClamps() {
        let model = temporaryModel()
        for _ in 0..<100 { model.zoomIn() }
        #expect(model.settings.zoom == ChatSettings.zoomRange.upperBound)
        #expect(!model.canZoomIn)

        for _ in 0..<200 { model.zoomOut() }
        #expect(model.settings.zoom == ChatSettings.zoomRange.lowerBound)
        #expect(!model.canZoomOut)
    }

    /// The font size the grid is actually drawn at stays inside the range the stepper
    /// offers, so zooming cannot reach a size the form could never have produced.
    @Test("zoom cannot push the size outside the font-size range")
    func zoomRespectsTheFontSizeRange() {
        let settings = ChatSettings(config: ConfigFile(url: temporaryFile()))
        settings.fontSize = ChatSettings.fontSizeRange.upperBound
        settings.zoom = ChatSettings.zoomRange.upperBound
        #expect(settings.effectiveFontSize == ChatSettings.fontSizeRange.upperBound)

        settings.fontSize = ChatSettings.fontSizeRange.lowerBound
        settings.zoom = ChatSettings.zoomRange.lowerBound
        #expect(settings.effectiveFontSize == ChatSettings.fontSizeRange.lowerBound)
    }

    // MARK: - Connect

    @Test("identity writes only the four identity keys")
    func identityWritesOnlyItself() throws {
        let url = temporaryFile()
        let config = ConfigFile(url: url)
        var settings = ConnectionSettings(
            host: "irc.example.org",
            port: 6697,
            useTLS: true,
            nick: "alice",
            realName: "Alice Example"
        )
        settings.altNick = "alice_"
        settings.rememberIdentity(in: config)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("server.nick = alice"))
        #expect(text.contains("server.alt-nick = alice_"))
        #expect(text.contains("server.real-name = Alice Example"))
        // The host and port are per-server and belong to the server list, not to a global
        // identity form. Writing them here is the bug this assertion exists to catch.
        #expect(!text.contains("server.host"))
        #expect(!text.contains("server.port"))
    }

    @Test("an emptied identity field removes its line rather than writing an empty one")
    func emptyIdentityFieldsAreRemoved() throws {
        let url = temporaryFile()
        let config = ConfigFile(url: url)
        var settings = ConnectionSettings(
            host: "irc.example.org",
            port: 6697,
            useTLS: true,
            nick: "alice",
            realName: ""
        )
        settings.altNick = "alice_"
        settings.rememberIdentity(in: config)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("server.alt-nick"))

        settings.altNick = ""
        settings.rememberIdentity(in: config)
        #expect(!(try String(contentsOf: url, encoding: .utf8).contains("server.alt-nick")))
    }

    @Test("accepted certificates are listed in host order and can be forgotten")
    func knownHostsListAndForget() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "caravan-hosts-\(UUID().uuidString)")
            .appending(path: "known_hosts")
        let hosts = KnownHosts(url: url)
        hosts.remember("AA:BB", for: "zeta.example")
        hosts.remember("CC:DD", for: "alpha.example")

        #expect(hosts.accepted().map(\.host) == ["alpha.example", "zeta.example"])
        #expect(hosts.accepted().first?.fingerprint == "CC:DD")

        hosts.forget("alpha.example")
        #expect(hosts.accepted().map(\.host) == ["zeta.example"])
        // And it is gone from the file, so the next launch asks again.
        #expect(KnownHosts(url: url).fingerprint(for: "alpha.example") == nil)
    }

    // MARK: - The tabs themselves

    /// Sounds is deliberately absent until prompt 13b brings settings for it. This is the
    /// assertion that notices if an empty one is ever added.
    @Test("every tab has a pane behind it")
    func everyTabIsBuilt() {
        #expect(
            OptionsPane.Tab.allCases.map(\.rawValue)
                == ["Connect", "IRC", "Display", "Colours", "Logging", "Other"]
        )
    }
}

/// Changing a colour has to reach text that is already on screen.
///
/// **Found by the live acceptance run, not by a test.** Switching the light and dark
/// tables needs no pass over the buffer — an indexed colour resolves itself against the
/// appearance drawing it — so the assumption was that overrides came free with that. They
/// do not: retuning what an index *means* changes the value rather than the appearance.
/// Resetting a colour left every line above it in the old palette.
@MainActor
@Suite("Palette overrides reach the buffer")
struct InlineColourRestyleTests {
    /// A controller holding one line that uses colour index 4, and its storage.
    private func coloured(palette: Palette) throws -> (MessageLogController, NSTextStorage) {
        let controller = MessageLogController(coalesceInterval: .zero, palette: palette)
        let scrollView = controller.displayView()
        var renderer = LineRenderer()
        renderer.palette = palette
        var fields = LineFields()
        fields.nick = "bob"
        fields.text = "\u{03}04RED\u{0F} plain"
        controller.append([renderer.line(kind: .message, fields: fields, now: Date())])
        controller.flush()
        let textView = try #require(scrollView.documentView as? NSTextView)
        return (controller, try #require(textView.textStorage))
    }

    private func colour(of substring: String, in storage: NSTextStorage) throws -> NSColor {
        let text = storage.string
        let range = try #require(text.range(of: substring))
        let index = text.distance(from: text.startIndex, to: range.lowerBound)
        let value = storage.attribute(.foregroundColor, at: index, effectiveRange: nil)
        return try #require((value as? NSColor)?.usingColorSpace(.sRGB))
    }

    @Test("an override applied after the line was drawn restyles it")
    func overrideRestylesExistingText() throws {
        let (controller, storage) = try coloured(palette: Palette())
        let before = try colour(of: "RED", in: storage)

        controller.palette = Palette(overrides: [4: RGB(0x12, 0x34, 0x56)])
        let after = try colour(of: "RED", in: storage)

        #expect(before != after)
        #expect(abs(after.redComponent - 0x12 / 255.0) < 0.01)
        #expect(abs(after.greenComponent - 0x34 / 255.0) < 0.01)
        #expect(abs(after.blueComponent - 0x56 / 255.0) < 0.01)
    }

    @Test("clearing an override puts the line back")
    func clearingAnOverrideRestoresTheTable() throws {
        let (controller, storage) = try coloured(palette: Palette(overrides: [4: RGB(1, 2, 3)]))
        let overridden = try colour(of: "RED", in: storage)

        controller.palette = Palette()
        let restored = try colour(of: "RED", in: storage)

        #expect(overridden != restored)
        // mIRC's red, which is what index 4 means with nothing overriding it.
        #expect(abs(restored.redComponent - 1.0) < 0.01)
    }

    /// §5: `^D` names an exact value and an override does not apply to it. A run with only
    /// a hex colour records no attribute, so a restyle must leave it exactly as drawn.
    @Test("a hex colour is not touched by an override")
    func hexColoursAreLeftAlone() throws {
        let controller = MessageLogController(coalesceInterval: .zero)
        let scrollView = controller.displayView()
        var fields = LineFields()
        fields.nick = "bob"
        fields.text = "\u{04}FF00FF PINK"
        controller.append([LineRenderer().line(kind: .message, fields: fields, now: Date())])
        controller.flush()
        let textView = try #require(scrollView.documentView as? NSTextView)
        let storage = try #require(textView.textStorage)

        let before = try colour(of: "PINK", in: storage)
        // An override for *every* index, so nothing but the hex rule can protect it.
        var overrides: [Int: RGB] = [:]
        for index in ChatSettings.overridableColours { overrides[index] = RGB(0, 0, 0) }
        controller.palette = Palette(overrides: overrides)
        #expect(try colour(of: "PINK", in: storage) == before)
    }

    @Test("the recorded indices survive the round trip into the text storage")
    func attributeSurvivesTheBridge() throws {
        let (_, storage) = try coloured(palette: Palette())
        let text = storage.string
        let range = try #require(text.range(of: "RED"))
        let index = text.distance(from: text.startIndex, to: range.lowerBound)
        let encoded = storage.attribute(.inlineColours, at: index, effectiveRange: nil) as? String
        #expect(InlineColours(encoded: try #require(encoded))?.foreground == 4)
    }

    @Test("the encoding round-trips, and rejects nonsense")
    func encoding() {
        for value in [
            InlineColours(foreground: 4),
            InlineColours(background: 12),
            InlineColours(foreground: 0, background: 15, isReversed: true),
            InlineColours(isReversed: true),
        ] {
            #expect(InlineColours(encoded: value.encoded) == value)
        }
        #expect(InlineColours(encoded: "") == nil)
        #expect(InlineColours(encoded: "4,5") == nil)
        #expect(InlineColours(encoded: "four,-,0") == nil)
        #expect(InlineColours(encoded: "4,-,maybe") == nil)
    }
}
