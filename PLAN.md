# mIRC-style IRC Client for macOS — Build Plan

A layered plan for building a native macOS IRC client modeled on mIRC. Each numbered
item is sized to be roughly one prompt / one focused work session, and each stage ends
at a point where the app is genuinely usable.

---

## 0. Architecture & Decisions

### Module layout (SwiftPM packages, app target on top)

| Module | Responsibility | I/O? |
|---|---|---|
| `IRCProtocol` | Message parse/serialize, IRCv3 tags, prefixes, ISUPPORT, CTCP, casemapping, wildcard masks | none — pure, heavily unit-tested |
| `IRCTransport` | `NWConnection` TCP/TLS, line framing, send queue, backpressure, reconnect/backoff, proxies | yes |
| `IRCSession` | Registration, CAP negotiation, SASL, connection state machine, channel/user state, typed event stream | yes |
| `IRCFormat` | mIRC control codes (`^B ^C ^I ^U ^R ^O ^K`) ⇄ `AttributedString`, 99-color palette | none |
| `ChatModel` | `@MainActor @Observable` app state: networks, windows, buffers, unread/activity | none |
| `Persistence` | Settings, server list, logs (system SQLite), Keychain | yes |
| `Scripting` | Aliases, identifiers, events, popups, timers (stage 3) | yes |
| `App` | SwiftUI + AppKit bridges, windows, dialogs | yes |

### Key technical choices

- **Swift 6 strict concurrency.** `IRCSession` is an `actor`; UI state is `@MainActor
  @Observable`. Events cross the boundary as an `AsyncStream` of `Sendable` enums.
- **Network.framework (`NWConnection`)** rather than raw BSD sockets — gives TLS,
  happy-eyeballs, path monitoring, and client-cert (CertFP) support for free.
- **UI: SwiftUI shell + AppKit where it counts.** The scrollback view should be an
  `NSTextView` (TextKit 2) wrapped in `NSViewRepresentable`. SwiftUI `List`/`ScrollView`
  degrades badly past a few thousand rich-text rows, and you lose native find, smooth
  selection across lines, and link detection. Everything else (sidebars, dialogs,
  settings) is plain SwiftUI.
- **Persistence:** SQLite for scrollback + full-text search; plain-text mIRC-style
  logs in parallel for user-facing logs. Nothing is written inside the source tree:
  settings in `~/.config/mirage/`, data in `~/.local/share/mirage/`, caches in
  `~/.cache/mirage/` (all honouring the matching `XDG_*` variables), and every
  credential in the macOS Keychain rather than any file.

### Settled

Full Xcode with a standard app target; public repo at `Lacuna-Research/irc-client`;
one branch and PR per prompt, squash-merged behind green CI. Zero external SwiftPM
dependencies — which rules out GRDB, so the persistence layer wraps the system
SQLite directly. See the decision entries in `BUILD-LOG.md` for the reasoning.

### Still open

1. **Scripting engine (stage 3):** reimplement a subset of the mIRC scripting language
   (authentic, big) vs. embed Lua/JavaScriptCore (fast, not mIRC). Leaning
   mIRC-subset, since script compatibility is much of the point. Not blocking.
2. **Distribution:** App Store sandbox vs. direct/notarized. DCC (incoming
   connections, arbitrary file writes) and identd (port 113) are
   painful-to-impossible sandboxed. Leaning direct, notarized, Sparkle for updates.
   Not blocking, but note the app target is already configured un-sandboxed.

### Testing strategy

- `irc-parser-tests` YAML corpus against `IRCProtocol` from day one, upstream commit
  SHA recorded in `Tests/Fixtures/VENDOR.md`.
- A scriptable fake IRC server for `IRCSession` integration tests.
- Ergo (or InspIRCd) in Docker for end-to-end smoke tests against a real ircd.

### Carry-forward notes

Items below may carry a `### Carry-forward` block, appended when earlier work turns up
something that item needs to know. Consume and delete it when the item is built, and
record in `BUILD-LOG.md` that you did. This is the same convention
`STAGE1-PROMPTS.md` uses, extended to stages that have no prompt file yet.

---

## Stage 1 — Basic (MVP: connect, join, chat)

Target: connect to Libera.Chat over TLS, join a channel, hold a conversation.

Stage 1 is broken into ten prompts in **`STAGE1-PROMPTS.md`**, which is authoritative
for scope, ordering, and status. It is deliberately not summarized here — two copies
of the same list drift, and the copy nobody edits is the one that gets read.

**Done when:** you can idle in `#test` on Libera and talk.

---

## Stage 2 — Intermediate (a mIRC daily driver)

10. **mIRC formatting codes.** Parse/render bold, italic, underline, strikethrough,
    monospace, reverse, reset, and `^C` colors including the extended 16–98 palette.
    Ctrl+K/B/U/I in the input box, plus a color picker strip.
11. **Multi-window model.** mIRC treebar/switchbar: network → channels/queries/status
    tree, per-window activity state (normal / activity / message / highlight coloring),
    ⌘1–9 and Ctrl+Tab switching, detachable windows.
12. **Multi-network.** Several simultaneous connections, each with independent state,
    nick, and identity.
13. **Queries & CTCP.** PM windows; `VERSION`, `PING`, `TIME`, `USERINFO`, `CLIENTINFO`,
    `FINGER`, `ACTION` handling and replies, with reply throttling.
14. **Full command set.** `/whois /whowas /who /mode /op /deop /voice /devoice /kick
    /ban /unban /kickban /topic /invite /notice /away /back /list /names /ignore /oper
    /server /disconnect /amsg /ame /say /ctcp /ping /clear /clearall`.
15. **Tab completion.** mIRC-style cycling nick completion with configurable suffix
    (`: ` at line start, ` ` elsewhere), plus channel and command completion.
16. **Modes.** Render mode changes readably, track channel modes, ban/quiet/invex list
    dialogs (`367`/`368`, `346`–`349`), channel modes sheet.
17. **Context menus.** Nick-list and channel right-click menus: whois, query, op/deop,
    voice, kick, ban, kickban, ignore, DCC chat/send, slap. Hard-coded now, script-driven
    in stage 3.
18. **Options dialog.** mIRC-shaped tabbed prefs: Connect, IRC, Display, Colors, Sounds,
    Logging, Mouse, Other.
19. **Server list / address book.** Groups, per-server nick + password + autojoin
    channels + perform-on-connect commands, connect-on-startup, favorites.
20. **Logging.** Per-network/per-channel plain-text logs in mIRC's layout, log viewer,
    "reload last N lines on join" so windows aren't empty after reconnect.
21. **Highlights & notifications.** Nick mention, custom keyword/regex list, per-window
    and per-event sounds, macOS notifications, Dock badge, menu-bar item.
22. **Ignore list.** Wildcard `nick!user@host` masks with mIRC-style level flags
    (`-pcntikm`), temporary ignores with duration.
23. **Notify list.** `MONITOR` where available, `ISON` polling as fallback; online/offline
    events, notify window, sounds.
24. **Channel list window.** `/list` with min/max user filters, name and topic search,
    sortable columns, join-on-double-click.
25. **URL catcher.** Clickable links in the buffer, a URL history window, copy/open all.
26. **Away system.** `/away`, auto-away on idle, optional away nick, away log capturing
    messages received while away.
27. **Flood protection.** Outbound send-rate throttling to avoid `Excess Flood`, inbound
    flood detection with auto-ignore.
28. **Authentication.** SASL PLAIN, EXTERNAL (CertFP), SCRAM-SHA-256; NickServ
    auto-identify fallback; all secrets in Keychain.
29. **IRCv3 capabilities.** `cap-notify`, `multi-prefix`, `away-notify`, `account-notify`,
    `extended-join`, `userhost-in-names`, `server-time`, `message-tags`, `echo-message`,
    `batch`, `chghost`, `invite-notify`, `setname`, `standard-replies`,
    `labeled-response`.
30. **Buffer utilities.** ⌘F find-in-buffer with highlight, copy with/without formatting,
    scroll-lock, jump-to-latest, mark line at last-read position.

**Done when:** you'd use this instead of your current client.

---

## Stage 3 — Advanced (mIRC parity)

31. **DCC.** CHAT, SEND, GET with resume, passive/reverse DCC for NAT, transfer manager
    window with progress and throughput, configurable port range, per-user trust
    prompts, drag-and-drop file onto a nick to send.
32. **Identd.** mIRC's built-in ident server on port 113 — requires a privileged port;
    either a small privileged helper or a documented `pfctl` redirect.
33. **Proxies.** SOCKS5 / HTTP CONNECT, Tor.
34. **Scripting engine** (the largest subsystem — plan several prompts for it alone):
    - Aliases: `/j /join $1-`
    - Identifiers: `$nick $chan $me $1- $time $rand $read $readini $len $iif` …
    - Variables: `%var`, `/set /unset /inc /dec`, `/var` locals
    - Remote events: `on 1:TEXT:*:#:{ }`, `on JOIN`, `ON ACTION`, `ON NOTICE`, `ON KICK`,
      `ON MODE`, `ON CONNECT`, `ON DISCONNECT`, `ON QUIT`, `ON INPUT`
    - Control flow: `/if /elseif /else /while /goto /return /halt /haltdef`
    - Timers: `/timer[N] <reps> <interval> <command>`
    - Popups: menu definitions for nicklist / channel / query / status / menubar
    - Script editor window with Aliases / Popups / Remote / Users / Variables tabs
    - A sandbox/permission model — mIRC scripts historically were a malware vector, so
      file and exec access must be gated.
35. **Themes.** Per-event color mapping (mIRC's Colors dialog), per-window fonts,
    importable/exportable theme files, light/dark aware.
36. **Customization.** Toolbar editor, F-key bindings, arbitrary keyboard shortcuts.
37. **User levels.** mIRC's users list with access levels driving script event matching.
38. **Paste protection.** Multi-line paste warning dialog with preview and line count.
39. **Text niceties.** Spell check, emoji picker, macOS text replacement/services.
40. **Bouncer support.** ZNC/soju: `draft/chathistory` playback, `znc.in/self-message`,
    per-network buffers, detach-aware behavior.
41. **History search.** SQLite FTS across all logged history, cross-network, with a
    dedicated search window.

---

## Stage 4 — Polish & release

42. **Accessibility.** VoiceOver over the buffer and nick list, keyboard-only operation,
    high contrast, Dynamic Type.
43. **Localization.** String catalogs; RTL layout sanity.
44. **Performance.** 10k+ lines/sec ingest, virtualized scrollback with memory caps,
    instrument the text pipeline.
45. **Diagnostics.** OSLog structured logging, opt-in crash reporting, a raw-traffic
    debug window.
46. **Release engineering.** Notarization, DMG, Sparkle auto-update, release notes.
47. **mIRC import.** Read `mirc.ini`, `servers.ini`, `aliases.ini`, `popups.ini`,
    `remote.ini` — a genuine differentiator for anyone migrating.
48. **Sync.** Optional iCloud settings/server-list sync.
49. **Companion app.** Optional iOS/iPadOS target reusing `IRCProtocol`/`IRCSession`.

---

## Suggested order of attack

Stages 1 and 2 in order; within stage 3, scripting is the long pole and everything
else can be interleaved around it. Items 10, 11, 19, and 20 are what make it *feel*
like mIRC — if you want the vibe early, pull those forward right after stage 1.
