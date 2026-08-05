import IRCProtocol
import Testing

@testable import IRCSession

/// Channel and membership state, driven by scripted server output.
///
/// Every case here is written as the lines a server actually sends, fed through the same
/// path ``IRCSession`` uses — 005 applied first, then translation, then the roster. The
/// roster is pure, so the awkward cases run instantly and there is no excuse for skipping
/// them.
@Suite("Channel roster")
struct ChannelRosterTests {
    /// Replays server lines into a roster exactly as the session does.
    private struct Harness {
        var roster: ChannelRoster
        private(set) var capabilities = ServerCapabilities()

        /// Every snapshot the session would have broadcast, in order.
        private(set) var snapshots: [Channel] = []

        init(nick: String) {
            roster = ChannelRoster(ownNick: nick)
        }

        mutating func feed(_ lines: String...) {
            for line in lines { feed(line: line) }
        }

        private mutating func feed(line: String) {
            guard let message = IRCMessage(line: line) else {
                Issue.record("unparseable test line: \(line)")
                return
            }
            if message.command.numericCode == 5 {
                capabilities.apply(tokens: ServerCapabilities.tokens(inISUPPORT: message))
                roster.updateCapabilities(capabilities)
            }
            for event in EventTranslator.events(for: message, capabilities: capabilities) {
                apply(event)
            }
        }

        mutating func apply(_ event: IRCEvent) {
            for name in roster.apply(event) {
                guard let channel = roster[name] else { continue }
                snapshots.append(channel)
            }
        }

        func channel(_ name: String) -> Channel? {
            roster[IRCChannelName(name, mapping: capabilities.caseMapping)]
        }

        /// The channels the last event produced snapshots for.
        func names(ofLast count: Int) -> [String] {
            snapshots.suffix(count).map(\.name.raw)
        }

        func nicks(in name: String) -> [String] {
            channel(name)?.orderedMembers.map(\.nick.raw) ?? []
        }

        /// Nicks with their highest-ranking prefix, as a nick list draws them.
        func displayNames(in name: String) -> [String] {
            guard let channel = channel(name) else { return [] }
            return channel.orderedMembers.map(channel.displayName(for:))
        }
    }

    /// A server declaring five prefix levels, so nothing can quietly assume `@%+`.
    private static let isupport =
        ":irc.example.org 005 alice CASEMAPPING=ascii CHANTYPES=# PREFIX=(qaohv)~&@%+ "
        + "CHANMODES=beI,k,l,imnpst :are supported by this server"

    private func harness(nick: String = "alice", isupport: String = isupport) -> Harness {
        var harness = Harness(nick: nick)
        harness.feed(isupport)
        return harness
    }

    // MARK: - Joining

    @Test("our own JOIN creates the channel; someone else's does not")
    func selfJoinCreatesTheBuffer() {
        var harness = harness()
        harness.feed(":bob!u@h JOIN #nowhere")
        #expect(harness.roster.order.isEmpty)

        harness.feed(":alice!u@h JOIN #swift")
        #expect(harness.channel("#swift")?.isJoined == true)
        #expect(harness.nicks(in: "#swift") == ["alice"])

        harness.feed(":bob!u@h JOIN #swift")
        #expect(harness.nicks(in: "#swift") == ["alice", "bob"])
        #expect(harness.channel("#swift")?.members[IRCNick("bob", mapping: .ascii)]?.host == "h")
    }

    @Test("channels keep join order, not alphabetical order")
    func joinOrder() {
        var harness = harness()
        harness.feed(":alice!u@h JOIN #zeta", ":alice!u@h JOIN #alpha", ":alice!u@h JOIN #mu")
        #expect(harness.roster.snapshots.map(\.name.raw) == ["#zeta", "#alpha", "#mu"])
    }

    // MARK: - NAMES

    /// Multi-prefix is stage 2's to negotiate, but a parser that stops after one prefix
    /// turns `@+bob` into a member called `+bob` the moment it is.
    @Test("NAMES arrives in batches, and every leading prefix is consumed")
    func namesInBatches() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":irc.example.org 353 alice = #swift :@+bob ~carol",
            ":irc.example.org 353 alice = #swift :dave %erin"
        )
        // Nothing is visible until 366: a half-applied nick list is worse than a late one.
        #expect(harness.nicks(in: "#swift") == ["alice"])

        harness.feed(":irc.example.org 366 alice #swift :End of /NAMES list")
        #expect(harness.displayNames(in: "#swift") == ["~carol", "@bob", "%erin", "alice", "dave"])
        let bob = harness.channel("#swift")?.members[IRCNick("bob", mapping: .ascii)]
        #expect(bob?.modes == ["o", "v"])
    }

    /// Ordering comes from the server's declared `PREFIX`, never a hardcoded `@%+`.
    @Test("the nick list is ordered by declared prefix rank, then casemapped alphabetical")
    func nickListOrdering() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":irc.example.org 353 alice = #swift :zoe ~amy &bea @cal %dot +eve Abe",
            ":irc.example.org 366 alice #swift :End of /NAMES list"
        )
        #expect(
            harness.displayNames(in: "#swift")
                == ["~amy", "&bea", "@cal", "%dot", "+eve", "Abe", "alice", "zoe"]
        )
    }

    /// A `JOIN` between the 353 and the 366 must survive the commit, or the person who
    /// joined during a large channel's NAMES burst simply disappears.
    @Test("a JOIN arriving mid-NAMES is not lost when the batch commits")
    func joinDuringNames() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":irc.example.org 353 alice = #swift :bob",
            ":carol!u@h JOIN #swift",
            ":irc.example.org 366 alice #swift :End of /NAMES list"
        )
        #expect(harness.nicks(in: "#swift") == ["alice", "bob", "carol"])
    }

    // MARK: - Leaving

    @Test("PART removes just that member")
    func otherPart() {
        var harness = harness()
        harness.feed(":alice!u@h JOIN #swift", ":bob!u@h JOIN #swift", ":bob!u@h PART #swift :bye")
        #expect(harness.nicks(in: "#swift") == ["alice"])
        #expect(harness.channel("#swift")?.isJoined == true)
    }

    /// The buffer-lifecycle invariant, from the other side: a buffer may outlive
    /// membership. Nothing here removes the channel.
    @Test("a KICK of ourselves leaves the buffer open in the not-joined state")
    func selfKick() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":bob!u@h JOIN #swift",
            ":bob!u@h KICK #swift alice :out"
        )
        let channel = harness.channel("#swift")
        #expect(channel != nil)
        #expect(channel?.isJoined == false)
        // We no longer know who is in there, and claiming otherwise would be a lie the
        // nick list tells until the next join.
        #expect(channel?.members.isEmpty == true)
        #expect(harness.roster.order.count == 1)
    }

    @Test("our own PART empties the channel but keeps it")
    func selfPart() {
        var harness = harness()
        harness.feed(":alice!u@h JOIN #swift", ":bob!u@h JOIN #swift", ":alice!u@h PART #swift")
        #expect(harness.channel("#swift")?.isJoined == false)
        #expect(harness.channel("#swift")?.members.isEmpty == true)
    }

    @Test("rejoining a buffer that outlived its membership starts from a clean member list")
    func rejoin() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":bob!u@h JOIN #swift",
            ":alice!u@h PART #swift",
            ":alice!u@h JOIN #swift"
        )
        #expect(harness.channel("#swift")?.isJoined == true)
        #expect(harness.nicks(in: "#swift") == ["alice"])
        #expect(harness.roster.order.count == 1)
    }

    /// A netsplit is this, thousands of times. Each affected channel is reported
    /// separately, because each one has a line to print and a nick list to redraw.
    @Test("a QUIT removes the user from every channel at once, reported per channel")
    func quitAcrossChannels() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #one",
            ":alice!u@h JOIN #two",
            ":alice!u@h JOIN #three",
            ":bob!u@h JOIN #one",
            ":bob!u@h JOIN #two",
            ":bob!u@h JOIN #three",
            ":carol!u@h JOIN #two"
        )
        let before = harness.snapshots.count
        harness.feed(":bob!u@h QUIT :Ping timeout")

        #expect(harness.snapshots.count == before + 3)
        #expect(harness.names(ofLast: 3) == ["#one", "#two", "#three"])
        for name in ["#one", "#two", "#three"] {
            #expect(!(harness.channel(name)?.contains(IRCNick("bob", mapping: .ascii)) ?? true))
        }
        #expect(harness.nicks(in: "#two") == ["alice", "carol"])
    }

    @Test("a QUIT from someone we share nothing with changes nothing")
    func quitOfAStranger() {
        var harness = harness()
        harness.feed(":alice!u@h JOIN #one")
        let before = harness.snapshots.count
        harness.feed(":stranger!u@h QUIT :gone")
        #expect(harness.snapshots.count == before)
    }

    // MARK: - Nick changes

    @Test("a NICK renames the user in every channel and keeps the list ordered")
    func nickChangeAcrossChannels() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #one",
            ":alice!u@h JOIN #two",
            ":bob!u@h JOIN #one",
            ":bob!u@h JOIN #two",
            ":irc.example.org MODE #one +o bob",
            ":bob!u@h NICK :zed"
        )
        #expect(harness.nicks(in: "#one") == ["zed", "alice"])
        #expect(harness.nicks(in: "#two") == ["alice", "zed"])
        // Op survives the rename: it is the same member, not a new one.
        #expect(harness.displayNames(in: "#one") == ["@zed", "alice"])
    }

    /// Under rfc1459 the nicks `Foo[]` and `foo{}` are the same user. A rename between
    /// them must not produce two rows in the nick list.
    @Test("a nick change colliding under rfc1459 casemapping stays one member")
    func nickChangeUnderRFC1459Casemapping() {
        var harness = harness(
            isupport: ":irc.example.org 005 alice CASEMAPPING=rfc1459 CHANTYPES=# "
                + "PREFIX=(ov)@+ :are supported by this server"
        )
        harness.feed(
            ":alice!u@h JOIN #swift",
            #":irc.example.org 353 alice = #swift :@Foo[]"#,
            ":irc.example.org 366 alice #swift :End of /NAMES list",
            ":foo{}!u@h NICK :foo^"
        )
        #expect(harness.nicks(in: "#swift") == ["foo^", "alice"])
        #expect(harness.channel("#swift")?.memberCount == 2)
        // `~` folds to `^` under rfc1459, so this is still the same person.
        #expect(harness.channel("#swift")?.contains(IRCNick("Foo~", mapping: .rfc1459)) == true)
    }

    @Test("our own NICK moves the roster's idea of who we are")
    func ownNickChange() {
        var harness = harness()
        harness.feed(":alice!u@h JOIN #swift", ":alice!u@h NICK :alice2")
        #expect(harness.roster.ownNick == IRCNick("alice2", mapping: .ascii))
        // And a self-part under the new nick is still recognised as ours.
        harness.feed(":alice2!u@h PART #swift")
        #expect(harness.channel("#swift")?.isJoined == false)
    }

    // MARK: - Topic

    @Test("332 sets the topic and 333 attributes it")
    func topicOnJoin() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":irc.example.org 332 alice #swift :Swift talk",
            ":irc.example.org 333 alice #swift bob 1700000000"
        )
        let topic = harness.channel("#swift")?.topic
        #expect(topic?.text == "Swift talk")
        #expect(topic?.setBy == "bob")
        #expect(topic?.setAt == 1_700_000_000)
    }

    @Test("331 is a topic that is set and empty, and a new topic drops the old attribution")
    func topicChanges() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":irc.example.org 331 alice #swift :No topic is set"
        )
        #expect(harness.channel("#swift")?.topic?.isEmpty == true)

        harness.feed(
            ":irc.example.org 333 alice #swift bob 1700000000",
            ":carol!u@h TOPIC #swift :something new"
        )
        let topic = harness.channel("#swift")?.topic
        #expect(topic?.text == "something new")
        #expect(topic?.setBy == "carol")
        // 333 described the *previous* topic; carrying its timestamp forward would date
        // this one to before it existed.
        #expect(topic?.setAt == nil)
    }

    // MARK: - Modes

    @Test("324 replaces the channel's modes, keyed ones included")
    func channelModes() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":irc.example.org 324 alice #swift +ntkl hunter2 50"
        )
        let channel = harness.channel("#swift")
        #expect(channel?.modes == ["n", "t"])
        #expect(channel?.modeArguments["k"] == "hunter2")
        #expect(channel?.modeArguments["l"] == "50")
        #expect(channel?.modeDescription == "+ntkl hunter2 50")
    }

    @Test("a membership MODE re-ranks the member rather than becoming a channel mode")
    func membershipModes() {
        var harness = harness()
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":bob!u@h JOIN #swift",
            ":irc.example.org MODE #swift +ov bob bob"
        )
        #expect(harness.displayNames(in: "#swift") == ["@bob", "alice"])
        #expect(harness.channel("#swift")?.modes.isEmpty == true)

        harness.feed(":irc.example.org MODE #swift -o bob")
        #expect(harness.displayNames(in: "#swift") == ["+bob", "alice"])
    }

    @Test("a MODE naming someone who is not here is ignored rather than inventing them")
    func modeForAbsentMember() {
        var harness = harness()
        harness.feed(":alice!u@h JOIN #swift", ":irc.example.org MODE #swift +o ghost")
        #expect(harness.nicks(in: "#swift") == ["alice"])
    }

    // MARK: - Join failures

    /// A join that failed left no state behind, and the channel it names may be one we
    /// have never seen.
    @Test("a join failure creates nothing")
    func joinFailureCreatesNothing() {
        var harness = harness()
        harness.feed(":irc.example.org 475 alice #swift :Cannot join channel (+k)")
        #expect(harness.roster.order.isEmpty)
        #expect(harness.snapshots.isEmpty)
    }

    // MARK: - Disconnect and reconnect

    /// Losing your entire tree because wifi dropped is hostile. Nothing vanishes.
    @Test("disconnecting empties every channel but keeps every buffer")
    func disconnect() {
        var harness = harness()
        harness.feed(":alice!u@h JOIN #one", ":alice!u@h JOIN #two", ":bob!u@h JOIN #one")
        harness.apply(.stateChanged(.disconnected(reason: .timedOut)))

        #expect(harness.roster.order.count == 2)
        #expect(harness.channel("#one")?.isJoined == false)
        #expect(harness.channel("#two")?.isJoined == false)
        #expect(harness.channel("#one")?.members.isEmpty == true)
    }

    /// A reconnect resets `ISUPPORT`, and a name folded under the old server's mapping
    /// would no longer match itself. The re-key is what stops a carried-over channel
    /// quietly becoming unreachable.
    @Test("a casemapping change re-keys the channels that survived it")
    func casemappingChangeRekeysChannels() {
        var harness = harness(
            isupport: ":irc.example.org 005 alice CASEMAPPING=ascii CHANTYPES=# "
                + "PREFIX=(ov)@+ :are supported by this server"
        )
        harness.feed(#":alice!u@h JOIN #Foo[]"#)
        #expect(harness.channel("#Foo[]") != nil)

        harness.feed(
            ":irc.example.org 005 alice CASEMAPPING=rfc1459 :are supported by this server"
        )
        // Same channel, now findable under the new mapping's folding — which is the whole
        // point: `#foo{}` and `#Foo[]` are one room on an rfc1459 server.
        #expect(harness.roster.order.count == 1)
        #expect(harness.roster[IRCChannelName("#foo{}", mapping: .rfc1459)] != nil)
        #expect(harness.roster.ownNick == IRCNick("alice", mapping: .rfc1459))
    }

    @Test("a PREFIX change re-ranks the nick list without losing anyone")
    func prefixChangeReordersMembers() {
        var harness = harness(
            isupport: ":irc.example.org 005 alice CASEMAPPING=ascii CHANTYPES=# "
                + "PREFIX=(ov)@+ :are supported by this server"
        )
        harness.feed(
            ":alice!u@h JOIN #swift",
            ":irc.example.org 353 alice = #swift :@bob +carol dave",
            ":irc.example.org 366 alice #swift :End of /NAMES list",
            ":irc.example.org 005 alice PREFIX=(vo)+@ :are supported by this server"
        )
        // `v` now outranks `o`, so carol comes first. Absurd for a real server to do, and
        // exactly the kind of thing a hardcoded @%+ ordering would get wrong.
        #expect(harness.displayNames(in: "#swift") == ["+carol", "@bob", "alice", "dave"])
    }

    // MARK: - Closing a buffer

    /// The other half of the invariant: membership never outlives its buffer, so closing
    /// is the one thing that removes a channel.
    @Test("only closing a buffer removes a channel from the roster")
    func closingRemovesTheChannel() {
        var harness = harness()
        harness.feed(":alice!u@h JOIN #one", ":alice!u@h JOIN #two")
        let name = IRCChannelName("#one", mapping: .ascii)
        let removed = harness.roster.remove(name)
        #expect(removed)
        #expect(harness.roster.snapshots.map(\.name.raw) == ["#two"])
        // Closing what is already closed is not an error, and not a second event.
        let removedAgain = harness.roster.remove(name)
        #expect(!removedAgain)
    }
}
