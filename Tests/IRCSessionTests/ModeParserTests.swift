import Testing

@testable import IRCSession

/// Which modes eat an argument, and what happens when the server never said.
///
/// The whole risk in a mode string is desynchronisation: consume one argument too many
/// and every mode after it on the line is wrong.
@Suite("Mode parsing")
struct ModeParserTests {
    private func capabilities(_ tokens: [String]) -> ServerCapabilities {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: tokens)
        return capabilities
    }

    private func changes(
        _ parameters: [String],
        tokens: [String] = ["PREFIX=(ov)@+", "CHANMODES=beI,k,l,imnpst"],
        isChannel: Bool = true
    ) -> [ModeChange] {
        ModeParser.changes(
            in: parameters,
            isChannel: isChannel,
            capabilities: capabilities(tokens)
        )
    }

    @Test("group C takes an argument when set and none when cleared")
    func argumentWhenSet() {
        #expect(
            changes(["+l-l", "50"]) == [
                ModeChange(isSet: true, mode: "l", argument: "50"),
                ModeChange(isSet: false, mode: "l"),
            ]
        )
    }

    @Test("group B takes an argument in both directions")
    func alwaysArgument() {
        #expect(
            changes(["+k-k", "hunter2", "hunter2"]) == [
                ModeChange(isSet: true, mode: "k", argument: "hunter2"),
                ModeChange(isSet: false, mode: "k", argument: "hunter2"),
            ]
        )
    }

    /// A server is free to declare `(qaohv)~&@%+`, and half the networks that matter do.
    @Test("membership modes take an argument because PREFIX says so, not CHANMODES")
    func prefixModes() {
        #expect(
            changes(
                ["+qh", "amy", "bea"],
                tokens: ["PREFIX=(qaohv)~&@%+", "CHANMODES=b,k,l,imnt"]
            )
                == [
                    ModeChange(isSet: true, mode: "q", argument: "amy"),
                    ModeChange(isSet: true, mode: "h", argument: "bea"),
                ]
        )
    }

    /// The choice that fails smallest. Guessing that an unknown mode takes an argument
    /// would swallow the next mode's and mis-parse the rest of the line.
    @Test("an undeclared mode is assumed to take no argument")
    func unknownMode() {
        #expect(
            changes(["+zo", "bob"]) == [
                ModeChange(isSet: true, mode: "z"),
                ModeChange(isSet: true, mode: "o", argument: "bob"),
            ]
        )
    }

    /// Without a default table a server that omits `CHANMODES` and then sends `+k` leaves
    /// the key unconsumed, and every mode after it is parsed against the wrong argument.
    @Test("RFC 2811's modes are assumed when CHANMODES is absent")
    func defaultChannelModes() {
        #expect(
            changes(["+kl", "hunter2", "50"], tokens: ["PREFIX=(ov)@+"]) == [
                ModeChange(isSet: true, mode: "k", argument: "hunter2"),
                ModeChange(isSet: true, mode: "l", argument: "50"),
            ]
        )
    }

    @Test("user modes never consume an argument")
    func userModes() {
        #expect(
            changes(["+io", "notanargument"], isChannel: false) == [
                ModeChange(isSet: true, mode: "i"),
                ModeChange(isSet: true, mode: "o"),
            ]
        )
    }

    /// A truncated line is not a reason to drop the mode: it happened either way, and the
    /// whole line is in `.raw`.
    @Test("a mode missing its argument is still reported, without one")
    func missingArgument() {
        #expect(changes(["+o"]) == [ModeChange(isSet: true, mode: "o")])
        #expect(changes([]).isEmpty)
    }

    /// A mode string with no leading sign is a set, which is what servers send in 324.
    @Test("a mode string without a leading sign is read as setting")
    func impliedPlus() {
        #expect(
            changes(["nt"]) == [
                ModeChange(isSet: true, mode: "n"),
                ModeChange(isSet: true, mode: "t"),
            ]
        )
    }
}
