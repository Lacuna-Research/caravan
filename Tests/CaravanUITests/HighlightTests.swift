import Foundation
import Testing

@testable import CaravanUI

/// What counts as somebody talking to you.
@MainActor
@Suite("Highlight rules")
struct HighlightRulesTests {
    private func rules() -> HighlightRules {
        HighlightRules(config: temporaryConfig())
    }

    @Test("your own nick highlights, as a word, until you turn it off")
    func ownNick() {
        let rules = rules()
        #expect(rules.matchesOwnNick)
        #expect(rules.matches("bob: look at this", ownNick: "bob"))
        #expect(!rules.matches("bobbins", ownNick: "bob"))
        #expect(!rules.matches("nothing here", ownNick: "bob"))

        // A toggle at all because somebody's nick is a common word.
        rules.matchesOwnNick = false
        #expect(!rules.matches("bob: look at this", ownNick: "bob"))
    }

    @Test("a keyword matches on word boundaries, and a phrase may contain spaces")
    func keywords() {
        let rules = rules()
        rules.matchesOwnNick = false
        rules.add(HighlightPattern(kind: .word, text: "swift"))
        rules.add(HighlightPattern(kind: .word, text: "build failed"))

        #expect(rules.matches("is swift any good", ownNick: "bob"))
        #expect(rules.matches("SWIFT", ownNick: "bob"), "case-insensitive")
        #expect(!rules.matches("swiftly", ownNick: "bob"), "a fragment is not a word")
        #expect(rules.matches("the build failed again", ownNick: "bob"))
        #expect(!rules.matches("the build worked", ownNick: "bob"))
    }

    @Test("a regex matches, case-insensitively")
    func regexes() {
        let rules = rules()
        rules.matchesOwnNick = false
        rules.add(HighlightPattern(kind: .regex, text: "^ship it"))
        #expect(rules.matches("ship it now", ownNick: "bob"))
        #expect(rules.matches("SHIP IT", ownNick: "bob"))
        #expect(!rules.matches("please ship it", ownNick: "bob"), "anchored at the start")
    }

    /// These arrive from a text field and from a hand-edited file.
    @Test("a pattern that will not compile costs the pattern, not the launch")
    func badRegex() {
        let rules = rules()
        rules.matchesOwnNick = false
        rules.add(HighlightPattern(kind: .regex, text: "[unclosed"))
        rules.add(HighlightPattern(kind: .word, text: "fine"))

        // Kept, listed as broken, and unable to match.
        #expect(rules.patterns.count == 2)
        #expect(rules.rejected.map(\.text) == ["[unclosed"])
        #expect(!rules.matches("[unclosed", ownNick: "bob"))
        // And the good one still works, which is the whole point of not refusing the lot.
        #expect(rules.matches("this is fine", ownNick: "bob"))
        // It is still the user's, so it can be removed.
        #expect(rules.remove(id: HighlightPattern(kind: .regex, text: "[unclosed").id))
        #expect(rules.rejected.isEmpty)
    }

    @Test("adding the same rule twice corrects it rather than stacking a second")
    func replacing() {
        let rules = rules()
        rules.add(HighlightPattern(kind: .word, text: "swift"))
        rules.add(HighlightPattern(kind: .word, text: "swift"))
        #expect(rules.patterns.count == 1)
        // Same text, different kind, is a different rule.
        rules.add(HighlightPattern(kind: .regex, text: "swift"))
        #expect(rules.patterns.count == 2)
    }

    // MARK: - The file

    /// The one deliberate difference from `ignore.<n>`'s format.
    @Test("the written form splits on the first space, so a phrase survives")
    func fileFormat() {
        let config = temporaryConfig()
        let rules = HighlightRules(config: config)
        rules.add(HighlightPattern(kind: .word, text: "build failed"))
        rules.add(HighlightPattern(kind: .regex, text: "ship ?it"))

        #expect(config.string("highlight.1") == "word build failed")
        #expect(config.string("highlight.2") == "regex ship ?it")
        #expect(HighlightRules.parse("word build failed")?.text == "build failed")
        #expect(HighlightRules.parse("regex ^a b c$")?.text == "^a b c$")
        #expect(HighlightRules.parse("nonsense x") == nil)
        #expect(HighlightRules.parse("word") == nil)
    }

    @Test("rules round-trip through the file, broken ones included")
    func persistence() {
        let config = temporaryConfig()
        let first = HighlightRules(config: config)
        first.matchesOwnNick = false
        first.add(HighlightPattern(kind: .word, text: "build failed"))
        first.add(HighlightPattern(kind: .regex, text: "[unclosed"))

        let second = HighlightRules(config: ConfigFile(url: config.url))
        #expect(!second.matchesOwnNick)
        #expect(second.patterns.map(\.text) == ["build failed", "[unclosed"])
        #expect(second.rejected.map(\.text) == ["[unclosed"])
    }

    /// `highlight.nick` is in the same family and is not an index; a rewrite must not eat it.
    @Test("the nick toggle survives a rewrite of the pattern list")
    func nickKeySurvives() {
        let config = temporaryConfig()
        let rules = HighlightRules(config: config)
        rules.matchesOwnNick = false
        rules.add(HighlightPattern(kind: .word, text: "one"))
        rules.add(HighlightPattern(kind: .word, text: "two"))
        rules.remove(id: HighlightPattern(kind: .word, text: "one").id)

        #expect(config.bool(HighlightRules.Key.ownNick) == false)
        #expect(config.string("highlight.1") == "word two")
        #expect(config.string("highlight.2") == nil)
    }

    @Test("patterns load in numeric order, not alphabetical")
    func numericOrder() {
        let config = temporaryConfig()
        for index in 1...11 { config.set("word w\(index)", forKey: "highlight.\(index)") }
        let rules = HighlightRules(config: config)
        #expect(rules.patterns.map(\.text).last == "w11")
        #expect(rules.patterns[1].text == "w2")
    }

    @Test("a draft says whether it would compile before it is added")
    func validity() {
        #expect(HighlightPattern(kind: .word, text: "anything [goes").isValid)
        #expect(HighlightPattern(kind: .regex, text: "fine").isValid)
        #expect(!HighlightPattern(kind: .regex, text: "[unclosed").isValid)
        #expect(!HighlightPattern(kind: .word, text: "").isValid)
    }
}

/// The three filters between a match and an interruption.
@MainActor
@Suite("Deciding to interrupt")
struct AlertDecisionTests {
    private func alerts(
        _ trigger: AlertTrigger = .highlightsAndPrivateMessages
    ) -> Alerts {
        let settings = ChatSettings(config: temporaryConfig())
        settings.alertTrigger = trigger
        return Alerts(settings: settings, deliver: { _ in })
    }

    private func decide(
        _ alerts: Alerts,
        activity: BufferActivity = .highlight,
        isConversation: Bool = false,
        isOwnMessage: Bool = false,
        isOnScreen: Bool = false,
        appIsActive: Bool = false,
        age: TimeInterval = 0
    ) -> Bool {
        let now = Date()
        return alerts.shouldAlert(
            activity: activity,
            isConversation: isConversation,
            isOwnMessage: isOwnMessage,
            isOnScreen: isOnScreen,
            appIsActive: appIsActive,
            at: now.addingTimeInterval(-age),
            now: now
        )
    }

    @Test("§18's default: highlights and private messages, not every message")
    func theDefault() {
        let alerts = alerts()
        #expect(decide(alerts, activity: .highlight))
        #expect(decide(alerts, activity: .highlight, isConversation: true))
        #expect(!decide(alerts, activity: .message))
        #expect(!decide(alerts, activity: .activity))
    }

    @Test("the other three triggers say what they say")
    func triggers() {
        #expect(!decide(alerts(.never), activity: .highlight))
        // Highlights only: a private message reaches `.highlight` too, so this is the one
        // that has to tell them apart by whether the buffer is a conversation.
        #expect(decide(alerts(.highlights), activity: .highlight))
        #expect(!decide(alerts(.highlights), activity: .highlight, isConversation: true))
        #expect(decide(alerts(.allMessages), activity: .message))
        #expect(!decide(alerts(.allMessages), activity: .activity))
    }

    @Test("your own words never interrupt you")
    func ownMessage() {
        #expect(!decide(alerts(), isOwnMessage: true))
    }

    /// The line is already in front of you.
    @Test("nothing interrupts you about a window you are looking at")
    func onScreen() {
        #expect(!decide(alerts(), isOnScreen: true, appIsActive: true))
        // Either alone is not enough: a visible buffer in a background app is unseen, and a
        // frontmost app looking at a different buffer is too.
        #expect(decide(alerts(), isOnScreen: true, appIsActive: false))
        #expect(decide(alerts(), isOnScreen: false, appIsActive: true))
    }

    /// **The filter that matters.** A bouncer reattach replays `CHATHISTORY` as ordinary
    /// messages, and the ones this client has not seen survive de-duplication — correctly.
    /// Fifty of them mentioning your nick would be fifty notifications on connect.
    @Test("history does not interrupt you")
    func staleness() {
        let alerts = alerts()
        #expect(decide(alerts, age: 1))
        #expect(decide(alerts, age: Alerts.staleAfter - 1))
        #expect(!decide(alerts, age: Alerts.staleAfter + 1))
        #expect(!decide(alerts, age: 3600))
    }

    @Test("a delivered alert is remembered, and the history is bounded")
    func history() {
        var received: [Alert] = []
        let settings = ChatSettings(config: temporaryConfig())
        let alerts = Alerts(settings: settings, deliver: { received.append($0) })
        for index in 1...150 {
            alerts.post(Alert(source: "#swift", sender: "bob", text: "\(index)", item: nil))
        }
        #expect(received.count == 150)
        #expect(alerts.delivered.count == 100)
        #expect(alerts.delivered.last?.text == "150")
    }

    /// A notification's two lines, which is all the user ever sees of this type.
    @Test("an alert reads as a line of chat")
    func wording() {
        let alert = Alert(source: "#swift on libera", sender: "bob", text: "hi", item: nil)
        #expect(alert.title == "#swift on libera")
        #expect(alert.body == "<bob> hi")
        #expect(Alert(source: "x", sender: nil, text: "hi", item: nil).body == "hi")
    }

    /// **A test bundle must not be able to make a noise on somebody's machine.**
    @Test("the real delivery refuses to fire outside an app bundle")
    func inertInTests() {
        #expect(!Alerts.isRunningInAnApp)
    }
}
