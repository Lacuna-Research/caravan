import AppKit
import Foundation
import IRCFormat
import Observation
import SwiftUI

/// The handful of appearance settings that exist by now.
///
/// Backed by the plain-text config at `$XDG_CONFIG_HOME/caravan/caravan.conf`, which is
/// where settings live for good — the `UserDefaults` this used to sit in was a stopgap
/// carried from prompt 7 to here. Naming the keys in one place is what made the move one
/// file's worth of work.
///
/// Everything is written on change and nothing is written on launch, so a file the user
/// has not touched stays empty and keeps taking the defaults.
@MainActor
@Observable
public final class ChatSettings {
    public enum Default {
        /// A `DateFormatter` pattern, not `strftime` — the brackets pass through as
        /// literals. Empty turns timestamps off entirely.
        public static let timestampFormat = "[HH:mm:ss]"
        public static let showsRawTraffic = false

        /// Lines kept per buffer. `MessageLogController`'s own default, named here
        /// because the settings form is now the thing that decides it.
        public static let scrollbackLines = 5000

        public static let nickListWidth = 180.0
        public static let nickListVisible = true

        /// Auto, per §5: the toggle is explicit, but its default defers to the system
        /// rather than making a first-run user find it.
        public static let paletteMode = Palette.Mode.auto

        /// On, per §6. mIRC did not colour nicks; every client since has, and a channel
        /// of twenty people is much harder to read without it.
        public static let coloursNicks = true

        /// What a Tab-completed nick is followed by. mIRC's defaults, and configurable
        /// for the same reason mIRC made them so: people are particular about it.
        public static let completionSuffix = CompletionStyle()

        /// mIRC's density was near-zero leading, not small text (§15.5) — but "normal"
        /// here is the natural line height rather than the tightest, so the default is a
        /// readable window and Compact is a thing you choose.
        public static let density = Density.normal

        /// Actual size. Zoom is a multiplier over the chosen font size rather than a
        /// second size, so ⌥⌘0 has something to return to.
        public static let zoom = 1.0

        /// **On, for the two kinds of buffer that hold a conversation.** mIRC shipped with
        /// logging off and a tab to turn it on, which means the log you want is the one you
        /// did not have. The cost is honest and stated on the Logging tab: plain text under
        /// your own data directory, which nothing uploads and a Reveal button will show you.
        public static let logsChannels = true
        public static let logsQueries = true

        /// **Off.** The status window is numerics, the MOTD and capability lines — a
        /// transcript of the client talking to itself, written afresh on every connect. It
        /// is available for somebody debugging a network, and it is not what "log my
        /// conversations" means.
        public static let logsStatus = false

        /// Lines put back when a window opens. The same number as
        /// `SessionConfiguration.chatHistoryLimit`'s default, deliberately: the two sources
        /// cover the same span, which is what makes the overlap worth de-duplicating.
        public static let logReloadLines = 50
    }

    /// The range the form offers, and the range a hand-edited file is held to. Zero is
    /// meaningful — it is how you keep logs without having them replayed at you.
    public static let logReloadRange = 0...1000

    /// Line height, as a multiplier over the font's natural one (§15.5, §15.6).
    ///
    /// **Density is line height, not point size**, and the presets are multipliers rather
    /// than absolutes so that a user who has asked for large text keeps it — §15.6 is
    /// explicit that a requested size is never clamped downward. Compact is 1.0, the
    /// font's own natural height, so nothing here can make a line shorter than the glyphs
    /// in it need.
    public enum Density: String, Sendable, Hashable, CaseIterable, Identifiable {
        case compact
        case normal
        case comfortable

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .compact: "Compact"
            case .normal: "Normal"
            case .comfortable: "Comfortable"
            }
        }

        public var lineHeightMultiplier: Double {
            switch self {
            case .compact: 1.0
            case .normal: 1.15
            case .comfortable: 1.35
            }
        }
    }

    /// What ⌘+ and ⌘− walk between, and what a hand-edited file is held to.
    public static let zoomRange = 0.5...3.0

    /// One step of ⌘+ or ⌘−. Multiplicative, so zooming out and back in returns exactly
    /// where it started rather than drifting.
    public static let zoomStep = 1.1

    /// The range the form offers, and the range a hand-edited file is clamped to.
    ///
    /// A cap of zero would silently make every buffer empty, and there is no honest way
    /// to render a client with no scrollback; a cap in the millions is a memory bug the
    /// user typed for themselves.
    public static let scrollbackRange = 100...100_000

    /// The same treatment for the font size: the form offers this range, and a file
    /// saying `chat.font-size = 0` gets a readable window rather than an invisible one.
    public static let fontSizeRange = 9.0...36.0

    public enum Key {
        public static let fontFamily = "chat.font-family"
        public static let fontSize = "chat.font-size"
        public static let timestampFormat = "chat.timestamp-format"
        public static let showsRawTraffic = "chat.raw-traffic"
        public static let scrollbackLines = "chat.scrollback-lines"
        public static let nickListWidth = "ui.nick-list-width"
        public static let nickListVisible = "ui.nick-list-visible"
        public static let paletteMode = "chat.palette"
        public static let coloursNicks = "chat.colour-nicks"
        public static let completionSuffixAtLineStart = "chat.completion-suffix-line-start"
        public static let completionSuffix = "chat.completion-suffix"
        public static let density = "chat.density"
        public static let zoom = "chat.zoom"
        public static let logsChannels = "log.channels"
        public static let logsQueries = "log.queries"
        public static let logsStatus = "log.status"
        public static let logReloadLines = "log.reload-lines"

        /// One key per overridden colour index — `chat.colour.4 = FF0000`. A *set* rather
        /// than a scalar, and the only setting of that shape so far: indices the user has
        /// not touched are absent rather than written out with their default, so the file
        /// stays as short as what was actually changed.
        public static let colourPrefix = "chat.colour."

        public static func colour(_ index: Int) -> String { "\(colourPrefix)\(index)" }
    }

    /// What a Tab-completed nick is followed by, at the start of a line and elsewhere.
    ///
    /// **Stored with the spaces written out**, because the config file cannot hold a value
    /// that begins or ends with one — whitespace around a value is not significant there,
    /// which is a deliberate property of the format rather than a limitation to work
    /// around. `_` stands for a space on the way in and out, so `: ` is written `:_`.
    public var completionSuffix: CompletionStyle {
        didSet {
            config.set(
                Self.encodeSuffix(completionSuffix.atLineStart),
                forKey: Key.completionSuffixAtLineStart
            )
            config.set(Self.encodeSuffix(completionSuffix.elsewhere), forKey: Key.completionSuffix)
        }
    }

    static func encodeSuffix(_ suffix: String) -> String {
        suffix.replacingOccurrences(of: " ", with: "_")
    }

    static func decodeSuffix(_ stored: String) -> String {
        stored.replacingOccurrences(of: "_", with: " ")
    }

    /// Which of the two base palettes mIRC's colour indices read, per §5.
    ///
    /// `auto` is not resolved here. The mode travels to the scrollback's `NSAppearance`
    /// and the colours resolve themselves against it, so this never has to ask what the
    /// system is doing — and never has to be told when the user changes it at sunset.
    public var paletteMode: Palette.Mode {
        didSet { config.set(paletteMode.rawValue, forKey: Key.paletteMode) }
    }

    /// Whether nicks are coloured by hash (§6).
    public var coloursNicks: Bool {
        didSet { config.set(coloursNicks, forKey: Key.coloursNicks) }
    }

    /// The user's replacements for mIRC's colour indices 0–15 (§5).
    ///
    /// **Only 0–15.** The extended 16–98 range is fixed RGB in the specification, so it is
    /// not the user's to retune; the two 16-colour tables are the ones tuned per appearance
    /// and therefore the ones somebody might disagree with.
    ///
    /// One value for both appearances, matching `Palette.overrides`: the user named a
    /// colour, and re-tuning what they typed would defeat the point of having named it.
    public var colourOverrides: [Int: RGB] {
        didSet {
            guard colourOverrides != oldValue else { return }
            // Removals first, read back from the file rather than diffed against `oldValue`
            // — a `chat.colour.7` somebody added by hand is a key this owns and must be
            // able to clear, and it was never in `oldValue` to be diffed.
            for key in config.keys(withPrefix: Key.colourPrefix) {
                let index = Int(key.dropFirst(Key.colourPrefix.count))
                if index == nil || colourOverrides[index!] == nil {
                    config.set(nil, forKey: key)
                }
            }
            for (index, colour) in colourOverrides {
                config.set(colour.hexString, forKey: Key.colour(index))
            }
        }
    }

    /// The indices a user may override. See ``colourOverrides``.
    public static let overridableColours = 0...15

    /// Line height, as a preset multiplier (§15.5).
    public var density: Density {
        didSet { config.set(density.rawValue, forKey: Key.density) }
    }

    /// The global zoom multiplier (§15.5). One for every buffer, never per window.
    public var zoom: Double {
        didSet {
            // The same re-entrant clamp `fontSize` documents: under `@Observable` a stored
            // property is a computed one, so writing to it inside its own `didSet` needs
            // the `return` or it recurses.
            let clamped = Self.zoomRange.clamping(zoom)
            guard clamped == zoom else {
                zoom = clamped
                return
            }
            config.set(zoom, forKey: Key.zoom)
        }
    }

    /// The nick list's width and whether it is showing.
    ///
    /// Here rather than in `@AppStorage` because one persistence mechanism is the point:
    /// a second store left behind is a second place to look when a setting does not stick.
    /// Global, like everything else — one nick-list width for every channel, which is what
    /// the previous storage gave them too. Not in the settings form: they are set by
    /// dragging the handle and clicking the toggle, and a form field for a thing you resize
    /// with the mouse is a form field nobody uses.
    public var nickListWidth: Double {
        didSet {
            let clamped = Self.nickListWidthRange.clamping(nickListWidth)
            guard clamped == nickListWidth else {
                nickListWidth = clamped
                return
            }
            config.set(nickListWidth, forKey: Key.nickListWidth)
        }
    }

    public var isNickListVisible: Bool {
        didSet { config.set(isNickListVisible, forKey: Key.nickListVisible) }
    }

    /// The range the drag handle allows, and the range a hand-edited file is held to.
    public static let nickListWidthRange = 120.0...420.0

    public var fontFamily: String {
        didSet { config.set(fontFamily, forKey: Key.fontFamily) }
    }

    public var fontSize: Double {
        didSet {
            // Note the `return`. Under `@Observable` a stored property becomes a computed
            // one, so assigning to it from inside its own `didSet` re-enters the setter —
            // which is a stack overflow, not a no-op, if the clamped value is not written
            // back the once and left alone. The second pass is a fixed point by
            // construction: clamping a clamped value changes nothing.
            let clamped = Self.fontSizeRange.clamping(fontSize)
            guard clamped == fontSize else {
                fontSize = clamped
                return
            }
            config.set(fontSize, forKey: Key.fontSize)
        }
    }

    public var timestampFormat: String {
        didSet { config.set(timestampFormat, forKey: Key.timestampFormat) }
    }

    /// Whether the status window shows wire traffic in both directions.
    ///
    /// Off by default. Turning it on starts appending from that moment: lines already in
    /// the buffer are not retroactively interleaved, and turning it off does not remove
    /// what was already shown. That is mIRC's `/debug` behaviour, and `/debug -i` is what
    /// reaches back into the ring buffer for what came before.
    public var showsRawTraffic: Bool {
        didSet { config.set(showsRawTraffic, forKey: Key.showsRawTraffic) }
    }

    /// Lines kept per buffer before the oldest are dropped.
    ///
    /// Clamped on the way in, because this number also arrives from a text editor.
    public var scrollbackLines: Int {
        didSet {
            let clamped = Self.scrollbackRange.clamping(scrollbackLines)
            guard clamped == scrollbackLines else {
                scrollbackLines = clamped
                return
            }
            config.set(scrollbackLines, forKey: Key.scrollbackLines)
        }
    }

    /// What gets written down. One toggle per kind of buffer, which is the granularity
    /// mIRC's Logging tab has and the granularity the question actually has: "log my
    /// channels but not my private messages" is a real preference, and "log #swift but not
    /// #offtopic" is a per-server setting nobody has asked for.
    public var logsChannels: Bool {
        didSet { config.set(logsChannels, forKey: Key.logsChannels) }
    }

    public var logsQueries: Bool {
        didSet { config.set(logsQueries, forKey: Key.logsQueries) }
    }

    public var logsStatus: Bool {
        didSet { config.set(logsStatus, forKey: Key.logsStatus) }
    }

    /// How much of a buffer's log is put back when its window opens.
    ///
    /// Clamped on the way in, because this number also arrives from a text editor.
    public var logReloadLines: Int {
        didSet {
            let clamped = Self.logReloadRange.clamping(logReloadLines)
            guard clamped == logReloadLines else {
                logReloadLines = clamped
                return
            }
            config.set(logReloadLines, forKey: Key.logReloadLines)
        }
    }

    /// Whether a buffer of this shape is written down.
    public func logs(_ buffer: any ChatBuffer) -> Bool {
        switch buffer {
        case is ChannelBuffer: logsChannels
        case is QueryBuffer: logsQueries
        default: logsStatus
        }
    }

    @ObservationIgnored private let config: ConfigFile

    public init(config: ConfigFile = .shared) {
        self.config = config
        self.fontFamily = config.string(Key.fontFamily) ?? ChatFont.defaultFamily
        self.fontSize = Self.fontSizeRange.clamping(
            config.double(Key.fontSize) ?? ChatFont.defaultSize
        )
        self.timestampFormat = config.string(Key.timestampFormat) ?? Default.timestampFormat
        self.showsRawTraffic = config.bool(Key.showsRawTraffic) ?? Default.showsRawTraffic
        self.scrollbackLines = Self.scrollbackRange.clamping(
            config.int(Key.scrollbackLines) ?? Default.scrollbackLines
        )
        self.nickListWidth = Self.nickListWidthRange.clamping(
            config.double(Key.nickListWidth) ?? Default.nickListWidth
        )
        self.isNickListVisible = config.bool(Key.nickListVisible) ?? Default.nickListVisible
        // An unknown value takes the default rather than refusing to launch: this file is
        // hand-edited, and `chat.palette = darkk` should cost you the setting, not the app.
        self.paletteMode =
            config.string(Key.paletteMode).flatMap(Palette.Mode.init(rawValue:))
            ?? Default.paletteMode
        self.coloursNicks = config.bool(Key.coloursNicks) ?? Default.coloursNicks
        self.completionSuffix = CompletionStyle(
            atLineStart: config.string(Key.completionSuffixAtLineStart)
                .map(Self.decodeSuffix) ?? Default.completionSuffix.atLineStart,
            elsewhere: config.string(Key.completionSuffix)
                .map(Self.decodeSuffix) ?? Default.completionSuffix.elsewhere
        )
        self.density =
            config.string(Key.density).flatMap(Density.init(rawValue:)) ?? Default.density
        self.zoom = Self.zoomRange.clamping(config.double(Key.zoom) ?? Default.zoom)
        self.logsChannels = config.bool(Key.logsChannels) ?? Default.logsChannels
        self.logsQueries = config.bool(Key.logsQueries) ?? Default.logsQueries
        self.logsStatus = config.bool(Key.logsStatus) ?? Default.logsStatus
        self.logReloadLines = Self.logReloadRange.clamping(
            config.int(Key.logReloadLines) ?? Default.logReloadLines
        )
        // An index outside 0–15, or a value that is not six hex digits, is skipped rather
        // than refused: this file is hand-edited, and a typo should cost you the one
        // colour, not the launch.
        var overrides: [Int: RGB] = [:]
        for key in config.keys(withPrefix: Key.colourPrefix) {
            guard let index = Int(key.dropFirst(Key.colourPrefix.count)),
                Self.overridableColours.contains(index),
                let value = config.string(key),
                let colour = RGB(hex: value)
            else { continue }
            overrides[index] = colour
        }
        self.colourOverrides = overrides
    }

    /// The size text is actually drawn at: the chosen size, zoomed.
    ///
    /// Clamped to the font-size range at the end so that zooming a 36pt font cannot leave
    /// the grid somewhere the size stepper could never have put it.
    public var effectiveFontSize: Double {
        Self.fontSizeRange.clamping(fontSize * zoom)
    }

    /// The one chat font, as AppKit and as SwiftUI want it.
    ///
    /// **Here rather than at each call site.** Four places used to build this expression
    /// from `fontFamily` and `fontSize`, which was three chances to forget the zoom the
    /// moment zoom existed.
    public var chatNSFont: NSFont {
        ChatFont.nsFont(family: fontFamily, size: effectiveFontSize)
    }

    public var chatFont: Font {
        ChatFont.font(family: fontFamily, size: effectiveFontSize)
    }

    /// The colours configured here, as the buffers and the renderer want them.
    public var palette: Palette {
        Palette(mode: paletteMode, overrides: colourOverrides, coloursNicks: coloursNicks)
    }

    /// A renderer configured from these settings.
    public var renderer: LineRenderer {
        LineRenderer(table: .mIRC, timestampFormat: timestampFormat, palette: palette)
    }
}

extension ClosedRange where Bound: Comparable {
    /// `value`, brought inside the range.
    func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
