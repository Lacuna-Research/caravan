import IRCProtocol
import Testing

@testable import IRCSession

/// The three-valued state that both halves of prompt 14 rest on.
@Suite("Notify tracking")
struct NotifyTrackerTests {
    private func tracker(_ nicks: [String] = ["bob", "carol"]) -> NotifyTracker {
        var tracker = NotifyTracker()
        _ = tracker.setWatched(nicks, mapping: .rfc1459)
        return tracker
    }

    /// **An unknown is not an absence.** The whole prompt turns on this.
    @Test("a nick with no answer yet is neither online nor offline")
    func unknownIsNotOffline() {
        let tracker = tracker()
        #expect(tracker.isOnline("bob", mapping: .rfc1459) == nil)
        #expect(tracker.states.allSatisfy { $0.isOnline == nil })
    }

    @Test("setting the list reports what to add and remove")
    func watchList() {
        var tracker = NotifyTracker()
        var change = tracker.setWatched(["bob", "carol"], mapping: .rfc1459)
        #expect(change.added.sorted() == ["bob", "carol"])
        #expect(change.removed.isEmpty)

        change = tracker.setWatched(["carol", "dave"], mapping: .rfc1459)
        #expect(change.added == ["dave"])
        #expect(change.removed == ["bob"])
        #expect(tracker.watched.map(\.raw) == ["carol", "dave"])
    }

    /// Dropping somebody must drop what we knew about them, or adding them back reports a
    /// change that did not happen.
    @Test("a nick taken off the list loses its known state")
    func removingForgets() {
        var tracker = tracker()
        _ = tracker.apply(nick: "bob", isOnline: true, mapping: .rfc1459)
        _ = tracker.setWatched(["carol"], mapping: .rfc1459)
        _ = tracker.setWatched(["bob", "carol"], mapping: .rfc1459)
        #expect(tracker.isOnline("bob", mapping: .rfc1459) == nil)
    }

    /// Servers re-send 730 for somebody already online after a `MONITOR S`.
    @Test("a repeat is not news")
    func repeatsAreNotChanges() {
        var tracker = tracker()
        let first = tracker.apply(nick: "bob", isOnline: true, mapping: .rfc1459)
        let again = tracker.apply(nick: "bob", isOnline: true, mapping: .rfc1459)
        let back = tracker.apply(nick: "bob", isOnline: false, mapping: .rfc1459)
        #expect(first)
        #expect(!again, "a server re-sending 730 has not told us anything")
        #expect(back)
    }

    /// A server telling us about somebody we did not ask about is not something to show,
    /// and adding them would make the list disagree with itself.
    @Test("somebody not on the list is not tracked")
    func unwatchedNicksAreIgnored() {
        var tracker = tracker()
        let changed = tracker.apply(nick: "mallory", isOnline: true, mapping: .rfc1459)
        #expect(!changed)
        #expect(tracker.states.count == 2)
    }

    @Test("nicks are matched under the server's casemapping")
    func casemapping() {
        var tracker = tracker(["Bob[home]"])
        // `[` and `{` are the same character under rfc1459 folding.
        let changed = tracker.apply(nick: "bob{home}", isOnline: true, mapping: .rfc1459)
        #expect(changed)
        #expect(tracker.isOnline("BOB[HOME]", mapping: .rfc1459) == true)
    }

    /// `ISON` names only who is online, so everything else on the list is offline as of
    /// that answer — the one place the inference is safe.
    @Test("an ISON reply says who is offline by omission")
    func ison() {
        var tracker = tracker(["bob", "carol", "dave"])
        let changes = tracker.applyISON(online: ["carol"], mapping: .rfc1459)
        #expect(changes.count == 3)
        #expect(tracker.isOnline("carol", mapping: .rfc1459) == true)
        #expect(tracker.isOnline("bob", mapping: .rfc1459) == false)
        // And a second identical reply is not three more changes.
        let repeated = tracker.applyISON(online: ["carol"], mapping: .rfc1459)
        #expect(repeated.isEmpty)
    }

    /// The rule that stops a reconnect announcing that all your friends just arrived.
    @Test("the baseline is taken once and reports both halves")
    func baseline() {
        var tracker = tracker(["bob", "carol", "dave"])
        #expect(!tracker.hasBaseline)
        _ = tracker.apply(nick: "bob", isOnline: true, mapping: .rfc1459)
        _ = tracker.apply(nick: "carol", isOnline: false, mapping: .rfc1459)

        let baseline = tracker.takeBaseline()
        #expect(tracker.hasBaseline)
        #expect(baseline.online == ["bob"])
        #expect(baseline.offline == ["carol"])
        // dave is in neither: not yet known is not offline.
        #expect(!baseline.online.contains("dave"))
        #expect(!baseline.offline.contains("dave"))
    }

    /// Answers from the last connection say nothing about this one.
    @Test("a reconnect forgets what it knew but keeps the list")
    func reset() {
        var tracker = tracker()
        _ = tracker.apply(nick: "bob", isOnline: true, mapping: .rfc1459)
        _ = tracker.takeBaseline()
        tracker.reset()
        #expect(!tracker.hasBaseline)
        #expect(tracker.isOnline("bob", mapping: .rfc1459) == nil)
        #expect(tracker.watched.map(\.raw) == ["bob", "carol"])
    }
}

/// The wire shapes presence arrives in.
@Suite("Presence numerics")
struct PresenceNumericTests {
    private func events(_ line: String) -> [IRCEvent] {
        guard let message = IRCMessage(line: line) else { return [] }
        return EventTranslator.events(for: message, capabilities: ServerCapabilities())
            .filter { if case .raw = $0 { return false } else { return true } }
    }

    /// Servers send bare nicks, `nick!user@host`, and several separated by commas.
    @Test("730 and 731 carry a list, with or without user@host")
    func monitorTargets() {
        #expect(
            EventTranslator.monitorTargets(["alice", "bob,carol"]) == ["bob", "carol"]
        )
        #expect(
            EventTranslator.monitorTargets(["alice", "bob!u@h,carol!u2@h2"]) == ["bob", "carol"]
        )
        #expect(EventTranslator.monitorTargets(["alice", "bob, carol"]) == ["bob", "carol"])
        #expect(EventTranslator.monitorTargets(["alice", ""]).isEmpty)
    }

    @Test("730 is online and 731 is offline")
    func onlineAndOffline() {
        #expect(
            events(":server 730 alice :bob!u@h") == [.presenceChanged(nick: "bob", isOnline: true)]
        )
        #expect(
            events(":server 731 alice :bob") == [.presenceChanged(nick: "bob", isOnline: false)]
        )
    }

    /// The names past the limit are indistinguishable from offline, which is the one way
    /// this feature can lie — so the user has to see it.
    @Test("a full monitor list is an error the user reads")
    func monitorListFull() throws {
        let event = try #require(events(":server 734 alice 30 dave :Monitor list is full").first)
        guard case .clientError(let text) = event else {
            Issue.record("expected a client error, got \(event)")
            return
        }
        #expect(text.contains("30"))
        #expect(text.contains("dave"))
    }

    @Test("303 is a baseline of who is online, and says nothing about the rest")
    func ison() {
        #expect(
            events(":server 303 alice :bob carol")
                == [.notifyBaseline(online: ["bob", "carol"], offline: [])]
        )
        #expect(events(":server 303 alice :") == [.notifyBaseline(online: [], offline: [])])
    }

    /// The server is the authority on our own away state; `/away` is only a request.
    @Test("305 and 306 are our own away state")
    func awayNumerics() {
        #expect(
            events(":server 305 alice :You are no longer marked away")
                == [.awayStateChanged(isAway: false)]
        )
        #expect(
            events(":server 306 alice :You have been marked as away")
                == [.awayStateChanged(isAway: true)]
        )
    }
}
