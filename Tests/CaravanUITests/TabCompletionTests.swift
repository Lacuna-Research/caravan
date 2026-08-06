import IRCSession
import Testing

@testable import CaravanUI

/// Tab completion's rules, as a pure decision: text and a caret in, text and a caret out.
///
/// Driven without a text view on purpose. Every rule worth arguing about — which suffix,
/// which source, what a second Tab does — is here rather than behind AppKit, and
/// `InputFieldTests` checks only that the keys reach it.
@MainActor
@Suite("Tab completion")
struct TabCompletionTests {
    private let sources = CompletionSources(
        nicks: ["alice", "Bob", "bobby", "carol"],
        channels: ["#swift", "#swift-users", "#music"],
        commands: CompletionSources.allCommands
    )

    /// Completes `text` with the caret at its end, which is where typing leaves it.
    private func complete(
        _ text: String,
        with completion: TabCompletion,
        backwards: Bool = false
    ) -> TabCompletion.Completion? {
        completion.complete(
            text: text,
            caret: text.count,
            sources: sources,
            backwards: backwards
        )
    }

    // MARK: - Nicks

    /// The distinction that makes `bob: hello` an address and `tell bob about it` a
    /// sentence.
    @Test("a nick opening the line takes the colon suffix, and elsewhere a space")
    func suffixDependsOnPosition() throws {
        let atStart = try #require(complete("ali", with: TabCompletion()))
        #expect(atStart.text == "alice: ")
        #expect(atStart.caret == atStart.text.count)

        let midLine = try #require(complete("tell ali", with: TabCompletion()))
        #expect(midLine.text == "tell alice ")
    }

    /// Leading whitespace is still the start of the line: ASCII art aside, a line that
    /// begins with a space and then a nick is an address like any other.
    @Test("indentation does not stop a nick opening the line")
    func indentedLineStart() throws {
        let completed = try #require(complete("  ali", with: TabCompletion()))
        #expect(completed.text == "  alice: ")
    }

    /// You should not have to know how somebody capitalises themselves to complete them,
    /// and what lands has to be *their* spelling, because that is what matches on the wire.
    @Test("matching ignores case and the candidate's own spelling is what lands")
    func caseInsensitive() throws {
        let completed = try #require(complete("bO", with: TabCompletion()))
        #expect(completed.text == "Bob: ")
    }

    @Test("no candidate means Tab did nothing, so it can do what Tab does")
    func noMatch() {
        #expect(complete("zzz", with: TabCompletion()) == nil)
        #expect(complete("", with: TabCompletion()) == nil)
        #expect(complete("hello ", with: TabCompletion()) == nil)
    }

    // MARK: - Cycling

    /// The whole point of the feature: a second Tab offers the next candidate rather than
    /// completing the completion.
    @Test("repeated Tab cycles, and wraps")
    func cycling() throws {
        let completion = TabCompletion()
        var text = "bo"
        for expected in ["Bob: ", "bobby: ", "Bob: "] {
            let step = try #require(
                completion.complete(text: text, caret: text.count, sources: sources)
            )
            #expect(step.text == expected)
            text = step.text
        }
    }

    @Test("Shift+Tab cycles backwards")
    func cyclingBackwards() throws {
        let completion = TabCompletion()
        let first = try #require(complete("bo", with: completion))
        #expect(first.text == "Bob: ")

        let back = try #require(
            completion.complete(
                text: first.text,
                caret: first.caret,
                sources: sources,
                backwards: true
            )
        )
        #expect(back.text == "bobby: ", "backwards from the first wraps to the last")
    }

    /// A cycle is only a cycle while the box is where the last completion left it.
    @Test("editing after a completion commits it, and the next Tab starts fresh")
    func editingCommits() throws {
        let completion = TabCompletion()
        let first = try #require(complete("bo", with: completion))
        #expect(first.text == "Bob: ")

        // What the text view does when the user types: any edit that is not a Tab.
        completion.commit()
        #expect(!completion.isCycling)

        let typed = "Bob: hi ca"
        let next = try #require(
            completion.complete(text: typed, caret: typed.count, sources: sources)
        )
        #expect(next.text == "Bob: hi carol ", "a fresh word, not a step in the old cycle")
    }

    /// Without this a cycle resumes over text the user went back and changed, rewriting
    /// a word they had already moved past.
    @Test("a caret somewhere else is not a continuation")
    func caretMovedEndsTheCycle() throws {
        let completion = TabCompletion()
        let first = try #require(complete("bo", with: completion))
        #expect(first.text == "Bob: ")

        // Same text, caret dragged back into the middle of the completed word. Whatever
        // this Tab does, it must not be "the next candidate in the cycle you left".
        let stepped = completion.complete(text: first.text, caret: 2, sources: sources)
        #expect(stepped?.text != "bobby: ", "must not step a cycle the caret has left")
    }

    // MARK: - Commands and channels

    @Test("a slash at the start of the line completes commands, with a space")
    func commandCompletion() throws {
        let completed = try #require(complete("/jo", with: TabCompletion()))
        #expect(completed.text == "/join ")
    }

    /// `/msg bob /me` is a message that contains a slash, not a command.
    @Test("a slash anywhere else is not a command")
    func slashMidLine() {
        #expect(complete("/msg bob /jo", with: TabCompletion()) == nil)
    }

    @Test("a channel prefix completes channels")
    func channelCompletion() throws {
        let completion = TabCompletion()
        let first = try #require(complete("#swi", with: completion))
        #expect(first.text == "#swift ")

        let second = try #require(
            completion.complete(text: first.text, caret: first.caret, sources: sources)
        )
        #expect(second.text == "#swift-users ")
    }

    /// Each source answers for its own shape. Offering nicks for `/jo` would put a nick
    /// where a command belongs and send it to the server as one.
    @Test("the three sources do not fall back to each other")
    func sourcesDoNotMix() {
        let nickNamedLikeACommand = CompletionSources(nicks: ["join"], commands: [])
        let completion = TabCompletion()
        #expect(
            completion.complete(text: "/jo", caret: 3, sources: nickNamedLikeACommand) == nil
        )
    }

    // MARK: - The configurable suffix

    /// mIRC has had this configurable for decades and people are particular about it.
    @Test("the nick suffix is configurable, at the line start and elsewhere")
    func configurableSuffix() throws {
        let style = CompletionStyle(atLineStart: ", ", elsewhere: "")
        let atStart = try #require(
            TabCompletion().complete(text: "ali", caret: 3, sources: sources, style: style)
        )
        #expect(atStart.text == "alice, ")

        let midLine = try #require(
            TabCompletion().complete(
                text: "tell ali",
                caret: 8,
                sources: sources,
                style: style
            )
        )
        #expect(midLine.text == "tell alice")
    }

    /// A channel is never something you address, however the address suffix is set.
    @Test("configuring the address suffix does not reach channels or commands")
    func suffixOnlyAppliesToNicks() throws {
        let style = CompletionStyle(atLineStart: "!! ", elsewhere: " ")
        let channel = try #require(
            TabCompletion().complete(text: "#swi", caret: 4, sources: sources, style: style)
        )
        #expect(channel.text == "#swift ")

        let command = try #require(
            TabCompletion().complete(text: "/jo", caret: 3, sources: sources, style: style)
        )
        #expect(command.text == "/join ")
    }

    /// The list exists so the input box does not keep a second copy of the command table.
    @Test("the offered commands are the parser's own")
    func commandsComeFromTheParser() {
        #expect(CompletionSources.allCommands == CommandParser.knownCommands)
        #expect(CompletionSources.allCommands.contains("join"))
    }
}
