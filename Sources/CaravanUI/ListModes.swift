import Foundation

/// One entry of a channel's ban, quiet, invite or except list.
public struct ListModeEntry: Sendable, Hashable, Identifiable {
    /// The mask — `*!*@evil.example`.
    public let mask: String
    /// Who set it, where the server says. Several do not.
    public let setBy: String?
    /// When, in Unix epoch seconds. Also optional.
    public let setAt: Int?

    public var id: String { mask }

    public init(mask: String, setBy: String? = nil, setAt: Int? = nil) {
        self.mask = mask
        self.setBy = setBy
        self.setAt = setAt
    }

    /// `on 7 Aug 2026 at 14:02`, or nothing at all.
    public var setAtDescription: String? {
        setAt.map {
            Date(timeIntervalSince1970: TimeInterval($0))
                .formatted(date: .abbreviated, time: .shortened)
        }
    }
}

/// The four list modes a channel can have, as the dialog offers them.
///
/// **One dialog with a picker, not four dialogs.** 367, 346, 348 and 728 are the same
/// numeric shape four times over; the only thing that differs is a mode letter and a word.
public enum ListMode: String, Sendable, Hashable, CaseIterable, Identifiable {
    case ban
    case quiet
    case invite
    case except

    public var id: String { rawValue }

    /// The mode letter to ask for and to set.
    ///
    /// `q` for quiet is the common spelling and is **not universal** — some networks use
    /// `+q` for channel owner instead, where asking for the list gets you an error rather
    /// than a list. `EXCEPTS` and `INVEX` in `ISUPPORT` name their own letters, which is
    /// why those two are read from the server rather than assumed.
    public func letter(capabilities: ChannelListModeLetters) -> Character {
        switch self {
        case .ban: "b"
        case .quiet: capabilities.quiet
        case .invite: capabilities.invite
        case .except: capabilities.except
        }
    }

    public var title: String {
        switch self {
        case .ban: "Bans"
        case .quiet: "Quiets"
        case .invite: "Invites"
        case .except: "Exceptions"
        }
    }

    /// What an empty list should say. "No bans" and "no exceptions" are different enough
    /// sentences to be worth writing out.
    public var emptyDescription: String {
        switch self {
        case .ban: "Nobody is banned from this channel."
        case .quiet: "Nobody is quieted in this channel."
        case .invite: "No invite exceptions are set."
        case .except: "No ban exceptions are set."
        }
    }
}

/// Which letters this server uses for the list modes it does not have to name.
public struct ChannelListModeLetters: Sendable, Hashable {
    public var quiet: Character
    public var invite: Character
    public var except: Character

    public init(quiet: Character = "q", invite: Character = "I", except: Character = "e") {
        self.quiet = quiet
        self.invite = invite
        self.except = except
    }
}
