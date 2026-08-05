import Foundation
import Testing

@testable import IRCProtocol

// Drives the vendored ircdocs/parser-tests corpus. See Fixtures/VENDOR.md for the
// upstream commit and how the JSON was produced.

enum Corpus {
    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        else {
            throw CorpusError.missing(name)
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    enum CorpusError: Error { case missing(String) }
}

// MARK: - msg-split

struct SplitFile: Decodable {
    struct Case: Decodable {
        struct Atoms: Decodable {
            var source: String?
            var verb: String?
            var params: [String]?
            var tags: [String: String?]?
        }
        var input: String
        var atoms: Atoms
    }
    var tests: [Case]
}

@Suite("Corpus: msg-split")
struct MessageSplitCorpusTests {
    @Test("every split case parses to the expected atoms")
    func splitsCorrectly() throws {
        let file = try Corpus.load("msg-split", as: SplitFile.self)
        #expect(file.tests.count > 30, "corpus looks truncated")

        for testCase in file.tests {
            let parsed = IRCMessage(line: testCase.input)
            guard let parsed else {
                Issue.record("failed to parse: \(testCase.input.debugDescription)")
                continue
            }

            // The corpus omits `verb` on the tag-only cases it expects to be dropped;
            // every case here has one.
            if let verb = testCase.atoms.verb {
                #expect(
                    parsed.command.wireForm == verb,
                    "verb mismatch for \(testCase.input.debugDescription)"
                )
            }

            #expect(
                parsed.parameters == (testCase.atoms.params ?? []),
                "params mismatch for \(testCase.input.debugDescription)"
            )

            #expect(
                parsed.source?.wireForm == testCase.atoms.source,
                "source mismatch for \(testCase.input.debugDescription)"
            )

            let expectedTags = (testCase.atoms.tags ?? [:]).mapValues { $0 ?? "" }
            #expect(
                parsed.tags.dictionary == expectedTags,
                "tags mismatch for \(testCase.input.debugDescription)"
            )
        }
    }
}

// MARK: - msg-join

struct JoinFile: Decodable {
    struct Case: Decodable {
        struct Atoms: Decodable {
            var source: String?
            var verb: String?
            var params: [String]?
            var tags: [String: String?]?
        }
        var desc: String?
        var atoms: Atoms
        var matches: [String]
    }
    var tests: [Case]
}

@Suite("Corpus: msg-join")
struct MessageJoinCorpusTests {
    @Test("every join case serializes to one of the accepted forms")
    func joinsCorrectly() throws {
        let file = try Corpus.load("msg-join", as: JoinFile.self)
        #expect(file.tests.count > 15, "corpus looks truncated")

        for testCase in file.tests {
            // Tag order is unspecified in the corpus atoms (it is a map), and several
            // cases accept multiple orderings. Sorting makes our output deterministic.
            let tags = IRCTags(
                (testCase.atoms.tags ?? [:])
                    .sorted { $0.key < $1.key }
                    .map { IRCTag(key: $0.key, value: $0.value) }
            )
            let message = IRCMessage(
                tags: tags,
                source: testCase.atoms.source.map { IRCSource(prefix: $0) },
                command: IRCCommand(token: testCase.atoms.verb ?? ""),
                parameters: testCase.atoms.params ?? []
            )
            #expect(
                testCase.matches.contains(message.wireForm),
                """
                \(testCase.desc ?? "case") produced \(message.wireForm.debugDescription), \
                expected one of \(testCase.matches.map(\.debugDescription))
                """
            )
        }
    }
}

// MARK: - userhost-split

struct UserhostFile: Decodable {
    struct Case: Decodable {
        struct Atoms: Decodable {
            var nick: String?
            var user: String?
            var host: String?
        }
        var source: String
        var atoms: Atoms
    }
    var tests: [Case]
}

@Suite("Corpus: userhost-split")
struct UserhostSplitCorpusTests {
    @Test("every source splits into the expected nick, user and host")
    func splitsSources() throws {
        let file = try Corpus.load("userhost-split", as: UserhostFile.self)
        for testCase in file.tests {
            let source = IRCSource(prefix: testCase.source)
            #expect(source.nick == testCase.atoms.nick, "nick for \(testCase.source)")
            #expect(source.user == testCase.atoms.user, "user for \(testCase.source)")
            #expect(source.host == testCase.atoms.host, "host for \(testCase.source)")
            // Round-trips exactly, which is what lets a trace echo the wire.
            #expect(source.wireForm == testCase.source)
        }
    }
}

// MARK: - mask-match

struct MaskFile: Decodable {
    struct Case: Decodable {
        var mask: String
        var matches: [String]?
        var fails: [String]?
    }
    var tests: [Case]
}

@Suite("Corpus: mask-match")
struct MaskMatchCorpusTests {
    @Test("masks match and fail exactly as the corpus says")
    func matchesMasks() throws {
        let file = try Corpus.load("mask-match", as: MaskFile.self)
        for testCase in file.tests {
            for source in testCase.matches ?? [] {
                #expect(
                    IRCMask.matches(mask: testCase.mask, source: source, mapping: .ascii),
                    "\(testCase.mask) should match \(source)"
                )
            }
            for source in testCase.fails ?? [] {
                #expect(
                    !IRCMask.matches(mask: testCase.mask, source: source, mapping: .ascii),
                    "\(testCase.mask) should not match \(source)"
                )
            }
        }
    }
}
