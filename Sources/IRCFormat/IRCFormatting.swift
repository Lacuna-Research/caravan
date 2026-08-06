/// mIRC's inline formatting codes, parsed into runs.
///
/// Pure, and the only reason this is its own module: the code table is a table, and a
/// table is worth testing exhaustively rather than through a text view. CI builds it on
/// Linux, so an accidental `import AppKit` fails a build rather than slipping past review.
///
/// **Colours come out as indices, not as colours.** `^C4` means "palette entry 4", and
/// which red that is depends on whether the window is light or dark — a decision this
/// module has no business making. `^D` is the exception and carries an exact triple,
/// because there the sender chose the colour rather than the palette.
public enum IRCFormatting {
    public static let bold: Character = "\u{02}"
    public static let italic: Character = "\u{1D}"
    public static let underline: Character = "\u{1F}"
    public static let strikethrough: Character = "\u{1E}"
    public static let monospace: Character = "\u{11}"
    public static let colour: Character = "\u{03}"
    public static let hexColour: Character = "\u{04}"
    public static let reverse: Character = "\u{16}"
    public static let reset: Character = "\u{0F}"

    /// Every character that means something rather than showing something.
    public static let allCodes: Set<Character> = [
        bold, italic, underline, strikethrough, monospace, colour, hexColour, reverse, reset,
    ]

    /// The highest palette index `^C` can name. 99 means "the window's own colour".
    public static let defaultColourIndex = 99

    /// Splits `text` into runs, dropping the codes themselves.
    ///
    /// Runs are contiguous and in order, and joining their text gives the line with every
    /// code removed. A code that toggles nothing visible still ends a run, which costs an
    /// extra run and keeps the parser from having to look ahead.
    public static func parse(_ text: String) -> FormattedText {
        var runs: [FormattedText.Run] = []
        var style = InlineStyle()
        var pending = ""
        var index = text.startIndex

        func closeRun() {
            guard !pending.isEmpty else { return }
            runs.append(FormattedText.Run(text: pending, style: style))
            pending = ""
        }

        while index < text.endIndex {
            let character = text[index]
            guard allCodes.contains(character) else {
                pending.append(character)
                index = text.index(after: index)
                continue
            }

            closeRun()
            index = text.index(after: index)

            switch character {
            case bold: style.isBold.toggle()
            case italic: style.isItalic.toggle()
            case underline: style.isUnderlined.toggle()
            case strikethrough: style.isStruckThrough.toggle()
            case monospace: style.isMonospaced.toggle()
            case reverse: style.isReversed.toggle()
            case reset: style.reset()
            case colour: index = applyColour(in: text, from: index, to: &style)
            case hexColour: index = applyHexColour(in: text, from: index, to: &style)
            default: break
            }
        }
        closeRun()
        return FormattedText(runs: runs)
    }

    /// Strips every code, leaving the text as it reads.
    ///
    /// For the places that must not show formatting *or* control characters: the tree, a
    /// window title, a notification. Cheaper than parsing and discarding the runs, and it
    /// is the operation those call sites actually mean.
    public static func stripping(_ text: String) -> String {
        guard text.contains(where: allCodes.contains) else { return text }
        return parse(text).plain
    }

    // MARK: - Colour codes

    /// `^C`, `^Cff`, `^Cff,bb` — and a bare `^C`, which clears both.
    ///
    /// **At most two digits each**, which is what makes `^C045` four followed by a literal
    /// `5` rather than an out-of-range 45. The comma only separates when a digit follows
    /// it; `^C4,text` is colour 4 and then a literal comma, and getting that wrong eats a
    /// character out of the middle of somebody's sentence.
    private static func applyColour(
        in text: String,
        from start: String.Index,
        to style: inout InlineStyle
    ) -> String.Index {
        var index = start
        guard let (foreground, afterForeground) = digits(in: text, from: index) else {
            style.foreground = nil
            style.background = nil
            return index
        }
        style.foreground = .indexed(foreground)
        index = afterForeground

        guard index < text.endIndex, text[index] == ",",
            let (background, afterBackground) = digits(in: text, from: text.index(after: index))
        else { return index }
        style.background = .indexed(background)
        return afterBackground
    }

    /// `^D` plus exactly six hex digits, and `^D` alone to clear.
    ///
    /// Not asked for by the roadmap item, but parsed all the same: a code left unparsed
    /// does not disappear, it renders as a control picture followed by six stray
    /// characters in the middle of a message.
    private static func applyHexColour(
        in text: String,
        from start: String.Index,
        to style: inout InlineStyle
    ) -> String.Index {
        var index = start
        guard let (foreground, afterForeground) = hexTriple(in: text, from: index) else {
            style.foreground = nil
            style.background = nil
            return index
        }
        style.foreground = .hex(foreground)
        index = afterForeground

        guard index < text.endIndex, text[index] == ",",
            let (background, afterBackground) = hexTriple(in: text, from: text.index(after: index))
        else { return index }
        style.background = .hex(background)
        return afterBackground
    }

    /// One or two decimal digits, and where they end.
    private static func digits(in text: String, from start: String.Index) -> (Int, String.Index)? {
        var index = start
        var value = 0
        var count = 0
        while index < text.endIndex, count < 2, let digit = text[index].wholeNumberValue,
            text[index].isASCII, (0...9).contains(digit)
        {
            value = value * 10 + digit
            count += 1
            index = text.index(after: index)
        }
        return count > 0 ? (value, index) : nil
    }

    private static func hexTriple(in text: String, from start: String.Index) -> (RGB, String.Index)?
    {
        guard let end = text.index(start, offsetBy: 6, limitedBy: text.endIndex),
            let colour = RGB(hex: text[start..<end])
        else { return nil }
        return (colour, end)
    }
}

/// A line, split into runs that each wear one style.
public struct FormattedText: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        public let text: String
        public let style: InlineStyle

        public init(text: String, style: InlineStyle) {
            self.text = text
            self.style = style
        }
    }

    public let runs: [Run]

    public init(runs: [Run]) {
        self.runs = runs
    }

    /// The line with every code removed.
    public var plain: String {
        runs.map(\.text).joined()
    }

    /// Whether anything here needs more than the line's own colour to render.
    public var isPlain: Bool {
        runs.allSatisfy(\.style.isPlain)
    }
}
