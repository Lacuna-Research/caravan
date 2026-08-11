import Foundation

/// The three directories the app is allowed to write to, per the XDG rule.
///
/// **Extracted when the third caller appeared.** `ConfigFile` and `KnownHosts` each carried
/// their own copy of this five-line dance; the chat log would have been the third, and three
/// copies of a path that is public API is three chances for one of them to drift. Both
/// keep their own `directory` property — those paths are documented and referenced — and
/// now compute it from here.
///
/// Nothing resolves to a path inside the app's own source tree, by rule.
public enum AppDirectories {
    /// `$XDG_CONFIG_HOME/caravan`, defaulting to `~/.config/caravan`.
    public static var config: URL { caravan(under: "XDG_CONFIG_HOME", fallback: ".config") }

    /// `$XDG_DATA_HOME/caravan`, defaulting to `~/.local/share/caravan`.
    public static var data: URL { caravan(under: "XDG_DATA_HOME", fallback: ".local/share") }

    /// `$XDG_CACHE_HOME/caravan`, defaulting to `~/.cache/caravan`. For things it would be
    /// no loss to delete — which is the test for whether something belongs here.
    public static var cache: URL { caravan(under: "XDG_CACHE_HOME", fallback: ".cache") }

    /// An empty variable is treated as unset, which is what the specification says and what
    /// a shell that exports `XDG_DATA_HOME=` accidentally produces.
    private static func caravan(under variable: String, fallback: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = ProcessInfo.processInfo.environment[variable]
        let root =
            base.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: fallback)
        return root.appending(path: "caravan")
    }
}
