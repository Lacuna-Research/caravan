import Testing

@testable import Diagnostics

@Test("Diagnostics target compiles, links, and is reachable from tests")
func diagnosticsTargetLinks() {
    #expect(DiagnosticsPlaceholder.isPlaceholder)
}
