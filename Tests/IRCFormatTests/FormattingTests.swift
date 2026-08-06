import Testing

@testable import IRCFormat

/// The formatting code table, exhaustively — it is a table, and it runs without a window.
@Suite("Inline formatting")
struct FormattingTests {
    /// The runs an input produces, as `(text, description-of-style)` pairs.
    private func runs(_ input: String) -> [(String, InlineStyle)] {
        IRCFormatting.parse(input).runs.map { ($0.text, $0.style) }
    }

    private func plain(_ input: String) -> String { IRCFormatting.parse(input).plain }

    // MARK: - Nothing to do

    @Test("text with no codes is one plain run")
    func noCodes() {
        let parsed = IRCFormatting.parse("hello there")
        #expect(parsed.runs.count == 1)
        #expect(parsed.plain == "hello there")
        #expect(parsed.isPlain)
    }

    @Test("empty input produces no runs at all")
    func empty() {
        #expect(IRCFormatting.parse("").runs.isEmpty)
        #expect(IRCFormatting.parse("").plain == "")
    }

    // MARK: - The switches

    @Test("each switch toggles on and off again")
    func toggles() {
        let parsed = IRCFormatting.parse("a\u{02}b\u{02}c")
        #expect(parsed.plain == "abc")
        #expect(parsed.runs.map(\.style.isBold) == [false, true, false])
    }

    @Test("switches are independent, not nested")
    func independentSwitches() {
        // Deliberately closed in the wrong order — there is no nesting to get wrong.
        let parsed = IRCFormatting.parse("\u{02}\u{1D}both\u{02}italic only")
        #expect(parsed.plain == "bothitalic only")
        let styled = parsed.runs.filter { !$0.text.isEmpty }
        #expect(styled.first { $0.text == "both" }?.style.isBold == true)
        #expect(styled.first { $0.text == "both" }?.style.isItalic == true)
        #expect(styled.first { $0.text == "italic only" }?.style.isBold == false)
        #expect(styled.first { $0.text == "italic only" }?.style.isItalic == true)
    }

    @Test("every documented switch is understood")
    func allSwitches() {
        let codes: [(Character, KeyPath<InlineStyle, Bool>)] = [
            (IRCFormatting.bold, \.isBold),
            (IRCFormatting.italic, \.isItalic),
            (IRCFormatting.underline, \.isUnderlined),
            (IRCFormatting.strikethrough, \.isStruckThrough),
            (IRCFormatting.monospace, \.isMonospaced),
            (IRCFormatting.reverse, \.isReversed),
        ]
        for (code, flag) in codes {
            let parsed = IRCFormatting.parse("\(code)on")
            #expect(parsed.runs.last?.style[keyPath: flag] == true, "code \(code.unicodeScalars)")
        }
    }

    @Test("reset clears everything at once")
    func reset() {
        let parsed = IRCFormatting.parse("\u{02}\u{1F}\u{03}4loud\u{0F}quiet")
        #expect(parsed.runs.last?.text == "quiet")
        #expect(parsed.runs.last?.style.isPlain == true)
    }

    // MARK: - Colour

    @Test("a colour code takes a foreground and an optional background")
    func colours() {
        #expect(IRCFormatting.parse("\u{03}4red").runs.last?.style.foreground == .indexed(4))

        let pair = IRCFormatting.parse("\u{03}4,12text").runs.last
        #expect(pair?.style.foreground == .indexed(4))
        #expect(pair?.style.background == .indexed(12))
        #expect(pair?.text == "text")
    }

    /// The rule that makes `^C045` four followed by a literal five rather than an
    /// out-of-range forty-five.
    @Test("at most two digits are consumed")
    func twoDigitLimit() {
        let parsed = IRCFormatting.parse("\u{03}045")
        #expect(parsed.plain == "5")
        #expect(parsed.runs.last?.style.foreground == .indexed(4))
    }

    /// Getting this wrong eats a character out of the middle of somebody's sentence.
    @Test("a comma with no digits after it is a comma")
    func commaIsNotAlwaysASeparator() {
        let parsed = IRCFormatting.parse("\u{03}4, then")
        #expect(parsed.plain == ", then")
        #expect(parsed.runs.last?.style.background == nil)
    }

    @Test("a bare colour code clears both colours")
    func bareColourResets() {
        let parsed = IRCFormatting.parse("\u{03}4,8loud\u{03}plain")
        #expect(parsed.runs.last?.text == "plain")
        #expect(parsed.runs.last?.style.foreground == nil)
        #expect(parsed.runs.last?.style.background == nil)
    }

    @Test("the whole documented index range parses")
    func everyIndex() {
        for index in 0...99 {
            let code = index < 10 ? "0\(index)" : "\(index)"
            let parsed = IRCFormatting.parse("\u{03}\(code)x")
            #expect(parsed.runs.last?.style.foreground == .indexed(index))
            #expect(parsed.runs.last?.text == "x")
        }
    }

    // MARK: - Hex colour

    @Test("hex colour carries an exact triple")
    func hexColour() {
        let parsed = IRCFormatting.parse("\u{04}FF8800warm")
        #expect(parsed.runs.last?.text == "warm")
        #expect(parsed.runs.last?.style.foreground == .hex(RGB(0xFF, 0x88, 0x00)))
    }

    @Test("a malformed hex colour clears rather than eating the text")
    func malformedHexColour() {
        let parsed = IRCFormatting.parse("\u{04}xyztext")
        #expect(parsed.plain == "xyztext")
    }

    // MARK: - Stripping

    /// What the tree, the window title and a notification want.
    @Test("stripping leaves the text as it reads")
    func stripping() {
        #expect(
            IRCFormatting.stripping("\u{02}bold\u{02} and \u{03}4,8colour\u{0F}")
                == "bold and colour"
        )
        #expect(IRCFormatting.stripping("nothing to do") == "nothing to do")
    }

    /// Control characters must not survive into a buffer, whatever the codes were doing.
    @Test("no control character survives a parse")
    func noControlCharactersSurvive() {
        let messy = "\u{02}a\u{03}4,8b\u{1D}c\u{16}d\u{1F}e\u{1E}f\u{11}g\u{04}00FF00h\u{0F}i"
        let plain = IRCFormatting.parse(messy).plain
        #expect(plain == "abcdefghi")
        #expect(!plain.contains { IRCFormatting.allCodes.contains($0) })
    }

    /// A code with nothing after it is a real thing to receive, and must not trap.
    @Test("a truncated code at the end of a line is harmless")
    func truncatedCodes() {
        #expect(IRCFormatting.parse("text\u{03}").plain == "text")
        #expect(IRCFormatting.parse("text\u{03}4,").plain == "text,")
        #expect(IRCFormatting.parse("text\u{04}").plain == "text")
        #expect(IRCFormatting.parse("text\u{04}FF00").plain == "textFF00")
    }

    /// Art is what this client is for, and a code in the middle of it must not swallow a
    /// column.
    @Test("text around codes keeps every other character")
    func artSurvives() {
        let art = "  \u{03}4/\\\u{03} \u{02}|\u{02}  "
        #expect(IRCFormatting.parse(art).plain == "  /\\ |  ")
    }

    // MARK: - Where the runs came from

    /// The input box styles raw text in place, so it needs to know which stretches of the
    /// original string each run came from — the codes are the gaps between them.
    @Test("every run's range points at its own text in the source")
    func runsCarryTheirRange() {
        for source in [
            "plain",
            "\u{02}bold\u{02} then not",
            "  \u{03}04,08red on yellow\u{0F} after",
            "\u{04}FF00FF hex\u{0F}",
            "\u{02}\u{1D}\u{1F}adjacent codes",
            "",
        ] {
            let formatted = IRCFormatting.parse(source)
            for run in formatted.runs {
                #expect(
                    String(source[run.range]) == run.text,
                    "run \"\(run.text)\" must sit at its own range in \"\(source.debugDescription)\""
                )
            }
        }
    }

    /// Ranges in order and never overlapping is what lets a caller treat the gaps as the
    /// codes. If two runs overlapped, a code would be styled as text.
    @Test("run ranges are in order and do not overlap")
    func rangesAreOrdered() {
        let source = "\u{02}a\u{02}b\u{03}4c\u{0F}d"
        let runs = IRCFormatting.parse(source).runs
        var cursor = source.startIndex
        for run in runs {
            #expect(run.range.lowerBound >= cursor)
            cursor = run.range.upperBound
        }
        #expect(cursor <= source.endIndex)
    }
}
