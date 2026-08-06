import AppKit
import IRCFormat

/// Draws the input box's own text the way the buffer will draw it.
///
/// **The opposite operation to the renderer's, and that is why it is separate code.**
/// `LineRenderer` parses the codes *out* and styles what is left; the input box has to
/// keep every character, because the string here is the thing that will be sent and a
/// caret has to be able to sit either side of a code. So this styles the stretches
/// between the codes and leaves the codes themselves visible and dim.
///
/// **The codes stay visible on purpose.** mIRC hides them, and an invisible control
/// character in an editable box gives you a caret that moves without visible cause and a
/// Backspace that appears to delete nothing. A dim marker says where the code is; the
/// styled text either side says what it does. `showsControlCharacters` on the layout
/// manager is what draws them, so the marker is AppKit's own rather than a substitution
/// that would change the string being sent.
enum InputStyling {
    /// Applies the parsed formatting to `storage`, over the whole of it.
    ///
    /// Idempotent: it sets every attribute it cares about on every run, so re-running it
    /// after each keystroke — which is what the text view does — cannot accumulate stale
    /// styling from an edit that removed a code.
    @MainActor
    static func apply(to storage: NSTextStorage, font: NSFont, palette: Palette) {
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        guard whole.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        // The baseline first, so a code that was just deleted leaves no styling behind.
        storage.setAttributes(
            [.font: font, .ligature: 0, .foregroundColor: NSColor.labelColor],
            range: whole
        )

        let formatted = IRCFormatting.parse(text)
        for run in formatted.runs where !run.style.isPlain {
            let range = NSRange(run.range, in: text)
            guard range.location != NSNotFound, NSMaxRange(range) <= whole.length else { continue }
            style(run.style, in: storage, range: range, font: font, palette: palette)
        }
        dimCodes(in: storage, text: text, formatted: formatted)
    }

    /// One run's worth of attributes, matching `LineRenderer.apply` exactly.
    @MainActor
    private static func style(
        _ style: InlineStyle,
        in storage: NSTextStorage,
        range: NSRange,
        font: NSFont,
        palette: Palette
    ) {
        var (foreground, background) = palette.colours(
            foreground: style.foreground,
            background: style.background
        )
        if style.isReversed {
            let swapped = (
                background ?? NSColor.textBackgroundColor, foreground ?? NSColor.textColor
            )
            (foreground, background) = swapped
        }
        if let foreground {
            storage.addAttribute(.foregroundColor, value: foreground, range: range)
        }
        if let background {
            storage.addAttribute(.backgroundColor, value: background, range: range)
        }
        // Typed, not a bare `.single`: the bare form resolves to SwiftUI's line style,
        // which the text storage has no key for. The same trap `LineRenderer` documents.
        if style.isUnderlined {
            storage.addAttribute(.underlineStyle, value: Self.singleLine.rawValue, range: range)
        }
        if style.isStruckThrough {
            storage.addAttribute(.strikethroughStyle, value: Self.singleLine.rawValue, range: range)
        }
        storage.addAttribute(
            .font,
            value: InlineTraits(style: style).applied(to: font),
            range: range
        )
    }

    /// Dims every code character, which is every character no run claimed.
    ///
    /// Derived from the runs rather than scanned for separately: `^C4` is one code and
    /// three characters, and a scan for `allCodes` would dim the `^C` and leave the `4`
    /// looking like text somebody meant to send.
    @MainActor
    private static func dimCodes(
        in storage: NSTextStorage,
        text: String,
        formatted: FormattedText
    ) {
        var cursor = text.startIndex
        for run in formatted.runs {
            dim(text[cursor..<run.range.lowerBound], in: storage, text: text)
            cursor = run.range.upperBound
        }
        dim(text[cursor...], in: storage, text: text)
    }

    @MainActor
    private static func dim(_ slice: Substring, in storage: NSTextStorage, text: String) {
        guard !slice.isEmpty else { return }
        let range = NSRange(slice.startIndex..<slice.endIndex, in: text)
        guard range.location != NSNotFound, NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
    }

    private static let singleLine: NSUnderlineStyle = .single
}
