import Foundation
import Observation

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
    }

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
    }

    /// The colours configured here, as the buffers and the renderer want them.
    public var palette: Palette {
        Palette(mode: paletteMode, coloursNicks: coloursNicks)
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
