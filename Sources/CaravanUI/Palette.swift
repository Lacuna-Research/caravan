import AppKit
import IRCFormat

/// Turns the palette indices `IRCFormat` hands back into colours a text view can draw.
///
/// The split is deliberate: `IRCFormat` is pure and knows the *tables*, this knows the
/// *window*. Which of the two base tables an index reads is the only thing the appearance
/// decides, and it is decided here so that nothing downstream has to ask.
///
/// **An index becomes a colour that resolves itself, not a colour.** Both tables are read
/// and the answer is an appearance-aware `NSColor`; which one is drawn is settled at draw
/// time by the appearance of the view drawing it. That is what lets the Auto / Light /
/// Dark toggle repaint text that is *already on screen* — a colour baked at render time
/// would leave the whole scrollback in the palette it arrived in, and the toggle would
/// look like it had done nothing until the next line came in.
public struct Palette: Sendable, Hashable {
    /// Auto follows the system appearance; either of the others pins it (§5).
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        case auto
        case light
        case dark

        public var title: String {
            switch self {
            case .auto: "Auto"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        /// The appearance a buffer draws in, or `nil` for `auto`, which takes the
        /// system's.
        ///
        /// **Pinning the palette pins the window with it.** The dark table is tuned for a
        /// dark background; drawing it on a white one is less legible than either half of
        /// the choice, so the mode sets the scrollback's `NSAppearance` and every colour
        /// in it — the mIRC indices, the nick hues and the semantic line colours alike —
        /// follows from there.
        @MainActor
        public var nsAppearance: NSAppearance? {
            switch self {
            case .auto: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    public var mode: Mode

    /// Per-index overrides, on top of whichever base table is in play (§5).
    ///
    /// One value for both appearances: the user named a colour, and re-tuning what they
    /// typed would defeat the point of an override.
    public var overrides: [Int: RGB]

    /// Whether nicks are coloured by hash at all (§6).
    public var coloursNicks: Bool

    /// Manual per-nick overrides, keyed by the folded nick — the same fold the hash uses,
    /// so an override set as `Bob` still applies to `bob`.
    public var nickOverrides: [String: RGB]

    public init(
        mode: Mode = .auto,
        overrides: [Int: RGB] = [:],
        coloursNicks: Bool = true,
        nickOverrides: [String: RGB] = [:]
    ) {
        self.mode = mode
        self.overrides = overrides
        self.coloursNicks = coloursNicks
        self.nickOverrides = nickOverrides
    }

    /// The colours for a run's foreground and background, resolved together.
    ///
    /// Together, because a sender who named both named a self-consistent pair and
    /// `MIRCPalette` treats that case differently — see its `resolving` documentation.
    /// A `nil` means "leave the window's own colour alone", which is what index 99 is.
    public func colours(
        foreground: InlineColour?,
        background: InlineColour?
    ) -> (foreground: NSColor?, background: NSColor?) {
        let light = resolve(foreground: foreground, background: background, appearance: .light)
        let dark = resolve(foreground: foreground, background: background, appearance: .dark)
        return (
            Self.colour(light: light.foreground, dark: dark.foreground),
            Self.colour(light: light.background, dark: dark.background)
        )
    }

    /// A nick's colour, or `nil` when nick colouring is off.
    public func colour(forNick nick: String) -> NSColor? {
        guard coloursNicks else { return nil }
        if let override = nickOverrides[nick.lowercased()] { return Self.nsColor(override) }
        return Self.colour(
            light: NickColour.colour(for: nick, appearance: .light),
            dark: NickColour.colour(for: nick, appearance: .dark)
        )
    }

    /// The pair as plain RGB, for one appearance.
    ///
    /// The appearance is a parameter rather than a property because every colour is
    /// resolved for *both*: the decision of which to draw belongs to the window, and is
    /// made later than this.
    private func resolve(
        foreground: InlineColour?,
        background: InlineColour?,
        appearance: MIRCPalette.Appearance
    ) -> (foreground: RGB?, background: RGB?) {
        // A hex colour is the sender naming an exact value, so no table and no override
        // applies — second-guessing it would overrule the one thing they were explicit
        // about.
        if case .hex(let value)? = foreground {
            return (value, hexOnly(background))
        }

        let foregroundIndex = foreground.flatMap(indexOf)
        let backgroundIndex = background.flatMap(indexOf)
        let overriddenBackground =
            hexOnly(background) ?? backgroundIndex.flatMap { overrides[$0] }
        if let index = foregroundIndex, let override = overrides[index] {
            return (override, overriddenBackground)
        }
        let resolved = MIRCPalette.resolving(
            foreground: foregroundIndex,
            background: backgroundIndex,
            appearance: appearance
        )
        return (resolved.foreground, overriddenBackground ?? resolved.background)
    }

    private func indexOf(_ colour: InlineColour) -> Int? {
        if case .indexed(let index) = colour { return index }
        return nil
    }

    private func hexOnly(_ colour: InlineColour?) -> RGB? {
        if case .hex(let value)? = colour { return value }
        return nil
    }

    /// One colour for a pair of table entries.
    ///
    /// Plain when the two agree — a hex triple, an override, anything in the fixed 16–98
    /// range — and appearance-resolving only when they differ. Most runs in a buffer take
    /// the plain path, and a dynamic colour that always answers the same thing is a
    /// closure call per draw for nothing.
    static func colour(light: RGB?, dark: RGB?) -> NSColor? {
        switch (light, dark) {
        case (nil, nil): nil
        case (let value?, nil), (nil, let value?): nsColor(value)
        case (let light?, let dark?) where light == dark: nsColor(light)
        case (let light?, let dark?): dynamicColour(light: light, dark: dark)
        }
    }

    /// A colour that reads its own value from whichever appearance is drawing it.
    ///
    /// This is the whole mechanism behind the palette toggle reaching text already on
    /// screen: AppKit resolves these at draw time, so pinning the scrollback's appearance
    /// — or the user switching the system's — repaints the buffer with no restyle pass and
    /// nothing to keep in sync.
    static func dynamicColour(light: RGB, dark: RGB) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? nsColor(dark)
                : nsColor(light)
        }
    }

    /// sRGB, explicitly. The wire gives eight bits per channel with no colour space, and
    /// letting AppKit pick a device space would make the same triple render differently on
    /// two displays.
    static func nsColor(_ colour: RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(colour.red) / 255,
            green: CGFloat(colour.green) / 255,
            blue: CGFloat(colour.blue) / 255,
            alpha: 1
        )
    }
}
