import Testing

@testable import IRCSession

@Test("IRCSession target compiles, links, and is reachable from tests")
func ircSessionTargetLinks() {
    #expect(IRCSessionPlaceholder.isPlaceholder)
}
