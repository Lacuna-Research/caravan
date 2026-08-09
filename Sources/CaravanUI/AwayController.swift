import AppKit
import Foundation
import Observation

/// Going away because you left, and saying what you missed when you get back.
///
/// **Off by default, and that is a decision rather than an oversight.** Auto-away speaks on
/// the user's behalf — it tells a channel full of people something about where you are —
/// and §19's "defaults taken without asking" covers the ones nobody would mind. This is not
/// one of them.
///
/// **The clock is the system's, not this window's.** "Away" means away from your desk, not
/// away from IRC; somebody reading a long backlog in another app has not left. macOS answers
/// that in one call and without any permission, and the call is behind a closure so a test
/// of the timer is not a test of waiting five minutes.
@MainActor
@Observable
public final class AwayController {
    /// Whether we are away because *this* decided it, rather than because the user typed
    /// `/away`.
    ///
    /// The distinction matters on the way back: coming back from an auto-away is automatic,
    /// and coming back from a deliberate `/away` is the user's to undo. A client that
    /// cancelled a typed `/away` the moment somebody touched the mouse would be useless to
    /// anybody who sets one before a meeting.
    public private(set) var isAutoAway = false

    /// How long the user has been idle, in seconds. Injectable for tests.
    ///
    /// `CGEventSource` rather than tracking our own key presses: it needs no permission, it
    /// counts the whole session's input, and it is one call.
    @ObservationIgnored public var idleSeconds: @MainActor () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0) ?? .null
        )
    }

    /// How often the idle clock is consulted. Not the timeout — the *resolution*.
    ///
    /// Fifteen seconds, which is finer than any timeout worth setting and coarse enough that
    /// a client sitting idle overnight is not the reason a laptop's fan comes on.
    public static let pollInterval = Duration.seconds(15)

    @ObservationIgnored private let settings: ChatSettings
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Called when the state should change. Set by `AppModel`, which owns the connections.
    @ObservationIgnored public var setAway: (@MainActor (String?) -> Void)?

    public init(settings: ChatSettings) {
        self.settings = settings
    }

    deinit {
        task?.cancel()
    }

    /// Starts the idle clock. Idempotent, so a setting can call it without checking.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AwayController.pollInterval)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One pass of the clock. Public so a test can drive it without sleeping.
    public func tick() {
        guard settings.autoAwayMinutes > 0 else {
            // Turned off while we were away for it: undo what we did, and leave a typed
            // `/away` alone.
            if isAutoAway { returnFromAway() }
            return
        }
        let threshold = TimeInterval(settings.autoAwayMinutes * 60)
        let idle = idleSeconds()
        if !isAutoAway, idle >= threshold {
            isAutoAway = true
            setAway?(settings.awayMessage.isEmpty ? "Away from keyboard" : settings.awayMessage)
        } else if isAutoAway, idle < threshold {
            returnFromAway()
        }
    }

    private func returnFromAway() {
        isAutoAway = false
        setAway?(nil)
    }

    /// The user typed `/away` themselves, so this must not undo it.
    public func noteManualAway() {
        isAutoAway = false
    }
}

/// What happened while you were gone.
///
/// **This is where the away log went.** `PLAN.md` asks for "an away log capturing what
/// arrived while you were gone", and most of that job is now done by things that did not
/// exist when the line was written: the unread rule marks where you left, the activity
/// states say which windows moved, prompt 12 logs every line and gives it a viewer, and
/// prompt 13b badges what was addressed to you. What none of them give is the one-glance
/// answer on return, so that is what this is — a count, not a second log viewer over data
/// already on screen.
public struct AwaySummary: Hashable, Sendable {
    public var highlights: Int
    public var conversations: Int
    public var busyBuffers: Int

    public init(highlights: Int = 0, conversations: Int = 0, busyBuffers: Int = 0) {
        self.highlights = highlights
        self.conversations = conversations
        self.busyBuffers = busyBuffers
    }

    public var isEmpty: Bool { highlights == 0 && conversations == 0 && busyBuffers == 0 }

    /// A sentence, or `nil` when nothing happened — which is worth saying nothing about
    /// rather than saying "nothing happened".
    public var sentence: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if highlights > 0 {
            parts.append("\(highlights) \(highlights == 1 ? "highlight" : "highlights")")
        }
        if conversations > 0 {
            parts.append(
                "\(conversations) private \(conversations == 1 ? "message" : "messages")"
            )
        }
        if busyBuffers > 0 {
            parts.append("activity in \(busyBuffers)")
        }
        return "While you were away: " + parts.joined(separator: ", ")
    }
}
