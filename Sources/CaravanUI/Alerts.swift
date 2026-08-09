import AppKit
import Diagnostics
import Foundation
import Observation
import UserNotifications

/// What is worth interrupting somebody for.
///
/// **One four-way choice rather than a toggle per kind of window.** §18 settles the default
/// as "highlights and private messages — not every message, not highlights alone", and that
/// is a *sentence*, not three checkboxes that happen to add up to it. Prompt 12's note
/// suggested copying `ChatSettings.logs(_:)`'s per-buffer-kind split; rereading §18 says
/// otherwise, and one setting that says what the design note says is easier to get right
/// than three that imply it.
public enum AlertTrigger: String, Sendable, Hashable, CaseIterable, Identifiable {
    case never
    case highlights
    case highlightsAndPrivateMessages
    case allMessages

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .never: "Never"
        case .highlights: "Highlights"
        case .highlightsAndPrivateMessages: "Highlights and private messages"
        case .allMessages: "Every message"
        }
    }

    /// Whether a buffer arriving at this state is worth an alert.
    func fires(for activity: BufferActivity, isConversation: Bool) -> Bool {
        switch self {
        case .never: false
        case .highlights: activity == .highlight && !isConversation
        case .highlightsAndPrivateMessages: activity == .highlight
        case .allMessages: activity >= .message
        }
    }
}

/// One thing worth telling the user about, once it has survived every filter.
public struct Alert: Hashable, Sendable {
    /// `#swift on libera`, which is the notification's title.
    public var source: String
    /// Who said it, or `nil` for something nobody said.
    public var sender: String?
    /// What they said.
    public var text: String
    /// Where to go when the notification is clicked.
    public var item: AppModel.SidebarItem?

    public init(source: String, sender: String?, text: String, item: AppModel.SidebarItem?) {
        self.source = source
        self.sender = sender
        self.text = text
        self.item = item
    }

    public var title: String { source }
    public var body: String { sender.map { "<\($0)> \(text)" } ?? text }
}

/// Decides whether a line is worth an interruption, and delivers it.
///
/// **Three filters stand between a match and a notification**, and each of them is a real
/// bug it prevents rather than a nicety:
///
/// - **Not your own words.** Your own message coming back under `echo-message` is not news.
/// - **Not something you are already looking at.** The app frontmost *and* that buffer on
///   screen means the line is already in front of you, and a notification for it is noise
///   with a sound attached.
/// - **Not history.** The important one. A bouncer reattach replays `CHATHISTORY` through
///   the ordinary message path, and the lines you have not seen before survive prompt 12's
///   de-duplication — correctly, because they are new to *this client*. Fifty of them
///   mentioning your nick is fifty notifications on connect. Anything whose `server-time`
///   is older than ``staleAfter`` does not alert.
///
/// A client that notifies too much is a client whose notifications get switched off, and
/// then the feature is worse than absent, because the user believes it is working.
@MainActor
@Observable
public final class Alerts {
    /// How old a line can be and still be worth interrupting for.
    ///
    /// Generous, because the failure modes are asymmetric: a notification five minutes late
    /// is mildly odd, and fifty notifications for last night's conversation is the thing
    /// that makes somebody turn the feature off for good. Not a setting — a user cannot be
    /// expected to have an opinion about it, and every value in the sane range behaves the
    /// same way for the case it exists for.
    public static let staleAfter: TimeInterval = 5 * 60

    /// What actually posts the notification and plays the sound.
    ///
    /// **Swappable, and the real one refuses to fire outside an `.app`.** A test bundle must
    /// never be able to post a user notification or make a noise on somebody's machine, and
    /// making that a property of the code rather than of test discipline is what stops it
    /// happening the one time nobody remembered.
    @ObservationIgnored public var deliver: @MainActor (Alert) -> Void

    /// Every alert delivered this session, newest last. For a test to assert on, and for
    /// the menu-bar item to have something to show.
    public private(set) var delivered: [Alert] = []

    @ObservationIgnored private let settings: ChatSettings

    public init(settings: ChatSettings, deliver: (@MainActor (Alert) -> Void)? = nil) {
        self.settings = settings
        self.deliver = deliver ?? Alerts.systemDelivery(settings: settings)
    }

    // MARK: - Deciding

    /// Whether this arrival is worth an interruption.
    ///
    /// Deliberately takes everything it needs rather than reaching for `NSApp` or the
    /// selection: the decision is then a function, and a function is testable without a
    /// window on screen or a notification centre to authorise it.
    public func shouldAlert(
        activity: BufferActivity,
        isConversation: Bool,
        isOwnMessage: Bool,
        isOnScreen: Bool,
        appIsActive: Bool,
        at when: Date,
        now: Date = Date()
    ) -> Bool {
        guard !isOwnMessage else { return false }
        guard settings.alertTrigger.fires(for: activity, isConversation: isConversation) else {
            return false
        }
        guard !(isOnScreen && appIsActive) else { return false }
        return now.timeIntervalSince(when) <= Self.staleAfter
    }

    /// Delivers one, and remembers it.
    public func post(_ alert: Alert) {
        delivered.append(alert)
        if delivered.count > 100 { delivered.removeFirst(delivered.count - 100) }
        deliver(alert)
    }

    public func clearHistory() {
        delivered.removeAll()
    }

    // MARK: - Delivering

    /// The real thing: a user notification and a sound.
    ///
    /// Built as a closure rather than a method so the guard below is evaluated per call and
    /// the whole apparatus is inert in anything that is not an app.
    static func systemDelivery(settings: ChatSettings) -> @MainActor (Alert) -> Void {
        { alert in
            guard isRunningInAnApp else { return }
            play(settings.alertSound)
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            // No sound from the notification itself: we play our own above, and a user who
            // chose "None" meant it. Two sounds for one line is the sort of thing that gets
            // a client's notifications switched off.
            UNUserNotificationCenter.current()
                .add(
                    UNNotificationRequest(
                        identifier: UUID().uuidString,
                        content: content,
                        trigger: nil
                    )
                ) { error in
                    guard let error else { return }
                    Log.ui.error(
                        "notification refused: \(error.localizedDescription, privacy: .public)"
                    )
                }
        }
    }

    /// **A test bundle must not be able to make a noise or post a notification.**
    /// `UNUserNotificationCenter.current()` is documented to trap when the bundle has no
    /// notification entitlement, which a `swift test` runner does not.
    static var isRunningInAnApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks once, on launch. A refusal is remembered by the system, and the Sounds tab says
    /// so rather than leaving the user wondering why nothing appears.
    public func requestAuthorisation() {
        guard Self.isRunningInAnApp else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge]) { _, error in
                guard let error else { return }
                Log.ui.error(
                    "notification authorisation: \(error.localizedDescription, privacy: .public)"
                )
            }
    }

    /// Plays a named system sound. An empty name means silence, which is a real choice.
    static func play(_ name: String) {
        guard !name.isEmpty, let sound = NSSound(named: name) else { return }
        sound.play()
    }

    /// The system sounds the picker offers, by name.
    ///
    /// Read from the system rather than hard-coded: the set differs by macOS version, and a
    /// list of names that no longer resolve is a picker full of silence.
    public static var availableSounds: [String] {
        let directories = [
            "/System/Library/Sounds",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds"),
        ]
        var names: Set<String> = []
        for directory in directories {
            let contents =
                (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for file in contents where !file.hasPrefix(".") {
                let name = (file as NSString).deletingPathExtension
                if NSSound(named: name) != nil { names.insert(name) }
            }
        }
        return names.sorted()
    }
}
