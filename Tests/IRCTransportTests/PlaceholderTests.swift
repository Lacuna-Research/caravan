import Testing

@testable import IRCTransport

@Test("IRCTransport target compiles, links, and is reachable from tests")
func ircTransportTargetLinks() {
    #expect(IRCTransportPlaceholder.isPlaceholder)
}
