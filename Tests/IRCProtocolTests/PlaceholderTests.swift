import Testing

@testable import IRCProtocol

@Test("IRCProtocol target compiles, links, and is reachable from tests")
func ircProtocolTargetLinks() {
    #expect(IRCProtocolPlaceholder.isPlaceholder)
}
