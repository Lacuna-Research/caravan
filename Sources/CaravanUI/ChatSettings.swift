import Foundation
import Observation

/// The handful of appearance settings that exist by now.
///
/// Backed by `UserDefaults`, and a stopgap in exactly the way the Connect sheet's storage
/// is: prompt 11 gives these a form and moves them to the plain-text config under
/// `$XDG_CONFIG_HOME/caravan/`, whose paths are public API. Naming the keys here rather
/// than at each use site is what makes that move one file's worth of work.
@MainActor
@Observable
public final class ChatSettings {
    public enum Default {
        /// A `DateFormatter` pattern, not `strftime` — the brackets pass through as
        /// literals. Empty turns timestamps off entirely.
        public static let timestampFormat = "[HH:mm:ss]"
        public static let showsRawTraffic = false
    }

    public enum Key {
        public static let fontFamily = "chatFontFamily"
        public static let fontSize = "chatFontSize"
        public static let timestampFormat = "timestampFormat"
        public static let showsRawTraffic = "showsRawTraffic"
    }

    public var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Key.fontFamily) }
    }

    public var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    public var timestampFormat: String {
        didSet { defaults.set(timestampFormat, forKey: Key.timestampFormat) }
    }

    /// Whether the status window shows wire traffic in both directions.
    ///
    /// Off by default. Turning it on starts appending from that moment: lines already in
    /// the buffer are not retroactively interleaved, and turning it off does not remove
    /// what was already shown. That is mIRC's `/debug` behaviour, and prompt 11's `-i`
    /// flag is what reaches back into the ring buffer for what came before.
    public var showsRawTraffic: Bool {
        didSet { defaults.set(showsRawTraffic, forKey: Key.showsRawTraffic) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fontFamily = defaults.string(forKey: Key.fontFamily) ?? ChatFont.defaultFamily
        let storedSize = defaults.double(forKey: Key.fontSize)
        self.fontSize = storedSize > 0 ? storedSize : ChatFont.defaultSize
        self.timestampFormat =
            defaults.string(forKey: Key.timestampFormat) ?? Default.timestampFormat
        self.showsRawTraffic =
            defaults.object(forKey: Key.showsRawTraffic) as? Bool ?? Default.showsRawTraffic
    }

    /// A renderer configured from these settings.
    public var renderer: LineRenderer {
        LineRenderer(table: .mIRC, timestampFormat: timestampFormat)
    }
}
