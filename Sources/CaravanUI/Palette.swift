import AppKit
import IRCFormat

/// Turns the palette indices `IRCFormat` hands back into colours a text view can draw.
///
/// The split is deliberate: `IRCFormat` is pure and knows the *tables*, this knows the
/// *window*. Which of the two base tables an index reads is the only thing the appearance
/// decides, and it is decided here so that nothing downstream has to ask.
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
    }

    public var mode: Mode

    /// The appearance `auto` resolved to. Passed in rather than read here so this type
    /// stays a value — the view layer reads `NSApp.effectiveAppearance` once and hands
    /// the answer down, which also makes every one of these paths testable.
    public var systemAppearance: MIRCPalette.Appearance

    /// Per-index overrides, on top of whichever base table is in play (§5).
    public var overrides: [Int: RGB]

    /// Whether nicks are coloured by hash at all (§6).
    public var coloursNicks: Bool

    /// Manual per-nick overrides, keyed by the folded nick — the same fold the hash uses,
    /// so an override set as `Bob` still applies to `bob`.
    public var nickOverrides: [String: RGB]

    public init(
        mode: Mode = .auto,
        systemAppearance: MIRCPalette.Appearance = .dark,
        overrides: [Int: RGB] = [:],
        coloursNicks: Bool = true,
        nickOverrides: [String: RGB] = [:]
    ) {
        self.mode = mode
        self.systemAppearance = systemAppearance
        self.overrides = overrides
        self.coloursNicks = coloursNicks
        self.nickOverrides = nickOverrides
    }

    /// Which base table is in play.
    public var appearance: MIRCPalette.Appearance {
        switch mode {
        case .auto: systemAppearance
        case .light: .light
        case .dark: .dark
        }
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
        // A hex colour is the sender naming an exact value, so no table and no override
        // applies — second-guessing it would overrule the one thing they were explicit
        // about.
        if case .hex(let value)? = foreground {
            return (Self.nsColor(value), background.flatMap(hexOnly))
        }

        let foregroundIndex = foreground.flatMap(indexOf)
        let backgroundIndex = background.flatMap(indexOf)
        if let index = foregroundIndex, let override = overrides[index] {
            return (Self.nsColor(override), resolvedBackground(backgroundIndex, background))
        }
        let resolved = MIRCPalette.resolving(
            foreground: foregroundIndex,
            background: backgroundIndex,
            appearance: appearance
        )
        return (
            resolved.foreground.map(Self.nsColor),
            resolvedBackground(backgroundIndex, background) ?? resolved.background.map(Self.nsColor)
        )
    }

    /// A nick's colour, or `nil` when nick colouring is off.
    public func colour(forNick nick: String) -> NSColor? {
        guard coloursNicks else { return nil }
        if let override = nickOverrides[nick.lowercased()] { return Self.nsColor(override) }
        return NickColour.colour(for: nick, appearance: appearance).map(Self.nsColor)
    }

    private func indexOf(_ colour: InlineColour) -> Int? {
        if case .indexed(let index) = colour { return index }
        return nil
    }

    private func hexOnly(_ colour: InlineColour) -> NSColor? {
        if case .hex(let value) = colour { return Self.nsColor(value) }
        return nil
    }

    private func resolvedBackground(_ index: Int?, _ colour: InlineColour?) -> NSColor? {
        if case .hex(let value)? = colour { return Self.nsColor(value) }
        return index.flatMap { overrides[$0] }.map(Self.nsColor)
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

extension MIRCPalette.Appearance {
    /// What the window is actually drawing, so `auto` can follow it.
    @MainActor
    public static var system: MIRCPalette.Appearance {
        let match = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }
}
