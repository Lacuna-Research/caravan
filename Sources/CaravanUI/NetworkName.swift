import Foundation

/// A network's stable, user-facing name — the thing everything durable keys on.
///
/// **This answers `PLAN.md`'s longest-standing open question**, and it is public API in
/// three places at once: `caravan.conf`'s `binding.N` keys, its `order.<name>.*` keys, and
/// (from stage 3) the `libera/#swift` form the command line and scripting address buffers
/// with. Renaming the *scheme* later would be a breaking change with no good migration,
/// which is why the shape is constrained rather than merely conventional.
///
/// Neither existing candidate served. `ConnectionViewModel.id` is a fresh `UUID` every
/// launch, so nothing written down survives a restart. `displayName` comes from `ISUPPORT
/// NETWORK=`, which the *server* owns and can change under you — a name your bindings hang
/// off must not be something a remote operator can rewrite.
///
/// So it belongs to the server-list entry, and therefore to the user.
public enum NetworkName {
    /// Characters a name may contain: lower-case ASCII letters, digits, `_` and `-`.
    ///
    /// **No slashes**, because `libera/#swift` is the addressing form and a name with a
    /// slash could not be told from a name plus a buffer. **No dots**, which is the less
    /// obvious one: both key families put the name in the *middle* of a dotted key —
    /// `order.libera.channels` — so a name containing a dot makes that key ambiguous to
    /// parse. Constraining the name is much cheaper than quoting the key.
    ///
    /// Lower-case only, so two entries cannot differ by case alone and leave the user
    /// guessing which of `Libera` and `libera` their binding meant.
    public static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Names are short because they are typed: `libera/#swift` at a command line, and in
    /// scripts. Long enough for `libera-staging`, short enough to stay a name.
    public static let maximumLength = 32

    /// Whether a string is usable as it stands.
    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maximumLength && name.allSatisfy(allowed.contains)
    }

    /// The best name for a host, before uniqueness is considered.
    ///
    /// `irc.libera.chat` → `libera`, `chat.freenode.net` → `freenode`,
    /// `soju.example.org` → `soju`, `127.0.0.1` → `127-0-0-1`. The rule is "the most
    /// specific label that is not noise": drop a leading `irc`/`chat`/`www`, then drop the
    /// public suffix if there is anything left, then take what remains.
    ///
    /// A guess, and it only has to be a *good* one — it is a default the user can edit,
    /// not a derivation anything depends on.
    public static func suggestion(forHost host: String) -> String {
        let cleaned = sanitised(host)
        guard !cleaned.isEmpty else { return "network" }

        var labels = cleaned.split(separator: "-").map(String.init)
        // An address rather than a name: every label is numeric, and there is no
        // meaningful one to pick, so keep the lot.
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return cleaned }

        if labels.count > 1, ["irc", "chat", "www"].contains(labels[0]) { labels.removeFirst() }
        if labels.count > 1 { labels.removeLast() }
        return labels.first.map(sanitised) ?? cleaned
    }

    /// A name made valid: lower-cased, with everything else turned into `-` and runs of
    /// `-` collapsed. Empty if nothing survives.
    public static func sanitised(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() {
            if allowed.contains(character) {
                result.append(character)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        while result.hasPrefix("-") { result.removeFirst() }
        return String(result.prefix(maximumLength))
    }

    /// `preferred`, or the first `preferred-2`, `preferred-3`, … that `taken` does not hold.
    ///
    /// Suffixed rather than refused: adding a second Libera account should not make the
    /// user invent a word for it before they can connect.
    public static func unique(_ preferred: String, taken: Set<String>) -> String {
        let base = isValid(preferred) ? preferred : "network"
        guard taken.contains(base) else { return base }
        for suffix in 2... {
            // Trimmed so the suffix survives the length cap rather than being cut off it,
            // which would produce a "unique" name equal to one already taken.
            let room = maximumLength - "-\(suffix)".count
            let candidate = "\(base.prefix(room))-\(suffix)"
            if !taken.contains(candidate) { return candidate }
        }
        return base
    }
}
