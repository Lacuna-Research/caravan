import Testing

@testable import IRCProtocol

/// The letter table. Pure, so it is exhaustive — and it runs on Linux beside the parser,
/// which is the reason it lives in this module rather than in the app.
@Suite("Ignore levels")
struct IgnoreLevelTests {
    @Test("every letter round-trips through its own parser")
    func roundTrip() throws {
        for (letter, level) in IgnoreLevel.letters {
            let parsed = try #require(IgnoreLevel(letters: String(letter)))
            #expect(parsed == level)
            #expect(parsed.letters == String(letter))
        }
    }

    @Test("letters combine, in table order whatever order they were written in")
    func combining() throws {
        let parsed = try #require(IgnoreLevel(letters: "tnp"))
        #expect(parsed == [.privateMessages, .notices, .ctcps])
        // Written back in the table's order, so a save does not reshuffle a hand-edited
        // file into a diff nobody can read past.
        #expect(parsed.letters == "pnt")
    }

    /// `/ignore -pz bob` acting on the `p` is how somebody comes to believe in a flag that
    /// does not exist.
    @Test("an unknown letter refuses the whole run rather than dropping one")
    func unknownLetters() {
        #expect(IgnoreLevel(letters: "z") == nil)
        #expect(IgnoreLevel(letters: "pz") == nil)
        #expect(IgnoreLevel(letters: "P") == nil, "the letters are lower case")
        #expect(IgnoreLevel(letters: "") == [])
    }

    @Test("everything is written and read as a star")
    func all() throws {
        #expect(IgnoreLevel.all.letters == "*")
        #expect(IgnoreLevel.all.summary == "everything")
        // Every letter set is exactly `all`, which is what makes `*` lossless.
        let everyLetter = try #require(IgnoreLevel(letters: "pcntikm"))
        #expect(everyLetter == .all)
    }

    /// `k` is the one level that keeps the line, so it must not be in the hiding set — a
    /// bug here means "strip his colours" silently means "never show him again".
    @Test("control codes are not a hiding level")
    func controlCodesDoNotHide() {
        #expect(!IgnoreLevel.hiding.contains(.controlCodes))
        #expect(IgnoreLevel.hiding.contains(.privateMessages))
        #expect(IgnoreLevel.hiding.contains(.movement))
        #expect(IgnoreLevel.all.contains(.controlCodes))
    }

    @Test("the summary is a sentence rather than the letters read back")
    func summaries() {
        #expect(IgnoreLevel.privateMessages.summary == "private messages")
        #expect(
            IgnoreLevel([.privateMessages, .notices]).summary == "private messages and notices"
        )
        #expect(
            IgnoreLevel([.privateMessages, .notices, .ctcps]).summary
                == "private messages, notices and CTCPs"
        )
        #expect(IgnoreLevel([]).summary == "nothing")
    }
}
