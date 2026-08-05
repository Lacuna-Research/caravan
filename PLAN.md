# mIRC-style Caravan for macOS — Build Plan

A layered plan for Caravan, a native macOS IRC client loosely inspired by the good
ol' days of mIRC. Each numbered
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
| `Scripting` | JavaScriptCore host, aliases, popups, timers (stage 3) | yes |
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
  settings in `~/.config/caravan/`, data in `~/.local/share/caravan/`, caches in
  `~/.cache/caravan/` (all honouring the matching `XDG_*` variables), and every
  credential in the macOS Keychain rather than any file.

### Settled

Full Xcode with a standard app target; public repo at `Lacuna-Research/caravan`;
one branch and PR per prompt, squash-merged behind green CI. Zero external SwiftPM
dependencies — which rules out GRDB, so the persistence layer wraps the system
SQLite directly, and settles scripting on JavaScriptCore since it ships with macOS.
See the decision entries in `BUILD-LOG.md` for the reasoning.

### Still open

**This is the single list of open questions.** Anything awaiting a decision belongs
here, whatever `BUILD-LOG.md` entry first raised it — that log is append-only and
approaching a thousand lines, so questions buried in it are questions nobody finds.
Delete an item from this list when it is answered, and record the answer as a
decision entry.

*Empty. Everything raised so far has been decided and recorded in `BUILD-LOG.md`.*

### Testing strategy

- `irc-parser-tests` YAML corpus against `IRCProtocol` from day one, upstream commit
  SHA recorded in `Tests/Fixtures/VENDOR.md`.
- A scriptable fake IRC server for `IRCSession` integration tests.
- Ergo (or InspIRCd) in Docker for end-to-end smoke tests against a real ircd.
- A local soju instance as the everyday development target. Preferable to pointing
  at Libera while iterating on the state machine — reconnecting a few hundred times
  against a real network during debugging is antisocial, and soju is a primary
  target we need to exercise anyway.

### Carry-forward notes

Items below may carry a `### Carry-forward` block, appended when earlier work turns up
something that item needs to know. Consume and delete it when the item is built, and
record in `BUILD-LOG.md` that you did. This is the same convention
`STAGE1-PROMPTS.md` uses, extended to stages that have no prompt file yet.

---

## Stage 1 — Basic (MVP: connect, join, chat)

Target: connect to Libera.Chat over TLS, join a channel, hold a conversation.

Stage 1 is broken into eleven prompts in **`STAGE1-PROMPTS.md`**, which is authoritative
for scope, ordering, and status. It is deliberately not summarized here — two copies
of the same list drift, and the copy nobody edits is the one that gets read.

**Done when:** you can idle in `#test` on Libera and talk.

---

## Stage 2 — Intermediate (a mIRC daily driver)

10. **mIRC formatting codes.** Parse/render bold, italic, underline, strikethrough,
    monospace, reverse, reset, and `^C` colors including the extended 16–98 palette.
    Ctrl+K/B/U/I in the input box, plus a color picker strip. Palettes per
    GUI-DESIGN-NOTES.md §5: an explicit three-state Auto / Light / Dark toggle (Auto
    follows the system appearance), a full alternate 16-colour palette for dark
    backgrounds — not a 0↔1 swap; the fixed 16–98 range mostly survives unchanged —
    and per-index user overrides on top. Nick colourisation per §6: hash-based
    per-nick colours seeded on the nick alone (not nick + network), manual per-nick
    override, and the generated palette contrast-checked against *both* backgrounds,
    so it cannot be a naive hue wheel.
11. **Multi-window model.** The tree's shape shipped with stage 1
    (GUI-DESIGN-NOTES.md §12); this item adds activity and navigation at scale
    (§1, §3, §8, §9, §11):
    - Per-buffer activity: mIRC's four colour-coded states (normal / activity /
      message / highlight), badges only for highlights. Collapsed network groups
      roll up the highest-severity state of their hidden children; jumping to a
      hidden buffer auto-expands and reveals it.
    - Next-unread and next-highlight keys — two separate bindings, not one; likely
      the highest-frequency navigation action in daily use.
    - Ctrl+Tab in MRU order — the Windows Alt-Tab model (tap to toggle the last
      two, hold and keep tapping to walk back), not Chrome's positional order.
    - A ⌘K fuzzy quick-switcher over buffer names across every network — names
      only; ⌘F-in-buffer and history search stay separate features.
    - ⌘1–9 buffer bindings (§11): nothing bound by default; assigned from the tree
      item's context menu (`Bind to ▸ 1…9`, taken digits shown); the digit shown in
      the tree; nine global slots, not nine per network; a binding attaches to
      buffer identity (network + buffer name), survives restarts in the plain-text
      config, and never reorders the tree. Activating a binding whose target is not
      open opens it, auto-joining only if the network is already connected. ⌘0
      stays reserved for Settings & Debug.
    - Detachable windows: one eject affordance shared by buffers and canvases
      (§1, §10) — this is where the Settings & Debug canvas gains its
      standalone-window mode.
    - Manual drag-to-reorder within a network, persisted, on top of join order.
    - `NSToolbar`, not a hand-rolled bar (§8): menu bar always; the icon toolbar
      optional but visible on first launch with a minimal set — connection state,
      sidebar toggle, nick-list toggle. The system customization palette makes
      mIRC's toolbar editor mostly not-work-we-do.
    The switchbar — mIRC's flat button strip — is deferred, not rejected (§2):
    revisit once the treebar is in real use.
12. **Multi-network.** Two modes behind one sidebar model, because a bouncer changes
    the shape of this: *direct*, one TCP connection per network with independent
    state, nick and identity; and *bouncer*, a single connection to soju where
    `soju.im/bouncer-networks` enumerates the upstream networks. The UI must not care
    which is in play. Fallback for the bouncer case is one connection per network
    with the network in the username (`<user>/<network>`), which is also how a
    stage-1 client reaches soju before capabilities exist.
13. **Queries & CTCP.** PM windows — sorted after channels in the same per-network
    list, bullet sigil, per GUI-DESIGN-NOTES.md §12, each with its header band
    showing conversational context: first and last message, and similar (§14);
    `VERSION`, `PING`, `TIME`, `USERINFO`, `CLIENTINFO`, `FINGER`, `ACTION`
    handling and replies, with reply throttling.

    ### Carry-forward

    - From prompt 6: `ACTION` is already unwrapped — `IRCEvent.message` carries
      `isAction` and text with the `\u{01}` wrapper stripped. Every *other* CTCP still
      arrives as an ordinary message with its delimiters intact, so a `VERSION` request
      currently renders as control characters in a channel window. That is the gap this
      item closes; `EventTranslator.unwrapAction` is where the general version belongs.
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
18. **Options.** mIRC-shaped tabbed prefs — Connect, IRC, Display, Colors, Sounds,
    Logging, Mouse, Other — built out on the Settings & Debug canvas from prompt 11,
    not a separate window (GUI-DESIGN-NOTES.md §10). Display gets the density and
    zoom model from §15.5: density is line height, not point size — a line-height
    multiplier with Compact / Normal / Comfortable presets as multipliers over the
    user's text-size preference (never clamping a requested size downward), zero
    paragraph spacing by default; zoom is global, with actual-size on ⌥⌘0 and in
    the View menu, since ⌘0 is the canvas; and the "Force monospaced grid" toggle from §15.3, off by
    default, clamping everything including emoji to one cell. The project-wide
    convention (§15.5): settings are global first; per-window overrides are added
    later if wanted.
19. **Server list — the Dashboard.** The Dashboard (GUI-DESIGN-NOTES.md §13) is a
    canvas, not a buffer: a peer row above the networks, bracketing the tree with
    Settings & Debug pinned at the bottom. It is the splash screen and the empty
    state — first run lands here, no separate onboarding flow, no wizard — and it
    holds the server list: groups, per-server nick + password + autojoin channels +
    perform-on-connect commands, connect-on-startup, favorites, plus "Add server".
    It replaces prompt 7's Connect sheet, which is shipped code to retire
    (`ConnectSheet` in `CaravanUI`), not a paper plan. No reserved shortcut; it is
    reachable from the tree. Its statistics — message counts, ping times, netsplit
    log, activity graph — stay deferred; see stage 4.
20. **Logging.** Per-network/per-channel plain-text logs in mIRC's layout, log viewer,
    "reload last N lines on join" so windows aren't empty after reconnect. Must
    reconcile with `chathistory`: against a bouncer the server backfills the same
    period the local log already covers, so the buffer needs de-duplication by
    message id / `server-time` rather than blindly concatenating both sources.
21. **Highlights & notifications.** Nick mention, custom keyword/regex list, per-window
    and per-event sounds, macOS notifications, Dock badge, menu-bar item. This is the
    dedicated notifications interface deferred from GUI-DESIGN-NOTES.md §18; the
    out-of-the-box triggers are highlights and private messages — not every message,
    not highlights alone.
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

    ### Carry-forward

    - From prompt 5: a server `ERROR` currently schedules a reconnect like any other
      failure, on the grounds that most of them are transient ("Closing link: ping
      timeout") and staying dead after one is worse. But a `K-line` or a throttle also
      arrives as `ERROR`, and reconnecting into one is exactly the antisocial behaviour
      this item exists to prevent. The backoff ceiling bounds it; recognising the
      permanent cases and stopping would be better. The signal is available: an `ERROR`
      arriving *before* 001 is far more likely to be a ban or a throttle than a dropped
      link.
28. **Authentication.** SASL PLAIN, EXTERNAL (CertFP), SCRAM-SHA-256; NickServ
    auto-identify fallback; all secrets in Keychain.

    ### Carry-forward

    - From prompt 4: TLS self-signed acceptance needs a user-facing trust decision.
      `IRCConnection` evaluates the certificate in a verify block, records subject and
      SHA-256 fingerprint in `acceptedCertificate`, and logs loudly when trust was not
      established — but with no UI to ask, `allowSelfSigned: true` still accepts. Turn
      that into trust-on-first-use: show the fingerprint, remember the decision per
      host, and warn when a remembered fingerprint changes. The transport already
      surfaces everything such a prompt needs.
29. **IRCv3 capabilities.** `cap-notify`, `multi-prefix`, `away-notify`, `account-notify`,
    `extended-join`, `userhost-in-names`, `server-time`, `message-tags`, `echo-message`,
    `batch`, `chghost`, `invite-notify`, `setname`, `standard-replies`,
    `labeled-response`. Plus the two that make soju work, promoted from stage 3
    because they change how buffers get populated and the logging and multi-window
    work needs that settled before building on top of it:
    `soju.im/bouncer-networks` to enumerate and switch upstream networks over one
    connection, and `draft/chathistory` to backfill what was missed while detached.
    `BouncerServ` needs nothing special — it is a query window.
30. **Buffer utilities.** ⌘F find-in-buffer with highlight, copy with/without
    formatting. (Scroll-lock and jump-to-latest shipped in prompt 7; the unread
    marker moved to prompt 10.)

**Done when:** you'd use this instead of your current client.

---

## Stage 3 — Advanced (mIRC parity)

31. **DCC.** CHAT, SEND, GET with resume, passive/reverse DCC for NAT, transfer manager
    window with progress and throughput, configurable port range, per-user trust
    prompts, drag-and-drop file onto a nick to send.
32. **Identd.** mIRC's built-in ident server on port 113 — requires a privileged port;
    either a small privileged helper or a documented `pfctl` redirect.
33. **Proxies.** SOCKS5 / HTTP CONNECT, Tor.
34. **Scripting** (the largest subsystem — plan several prompts for it alone).
    **JavaScript via JavaScriptCore, not the mIRC scripting language.** Two layers,
    mirroring mIRC's own aliases/popups/remote split — the spirit, not the syntax:

    *Declarative layer, no programming required.* This is the 80% case and it must
    stay a one-liner, because "three lines to auto-op a friend" is most of why mIRC
    scripting caught on.
    - Aliases: `j = /join $1-` in a plain text file
    - Popups: menu definitions for nicklist / channel / query / status / menubar
    - Simple event → command bindings for the cases that need no logic

    *JavaScript layer, for everything else.*
    - Event handlers over the same `IRCEvent` stream the UI consumes
    - A capability-scoped `irc` object: send, join, part, query client state, timers
    - No ambient authority. A bare `JSContext` has no `require`, `process`, `fetch`,
      `XMLHttpRequest`, `WebSocket` or `localStorage` — verified, see `BUILD-LOG.md`.
      Filesystem and network access are injected deliberately or not at all, and are
      gated by a per-script permission prompt. mIRC scripts were historically a
      malware vector precisely because the language had ambient authority; starting
      from zero and opting in is a structurally better position than restricting.
    - `JSContext.isInspectable` lets Safari Web Inspector attach: real breakpoints and
      a console, which mIRC never had.
    - Script editor window, and a `.d.ts` shipped for editor autocomplete.

    **Open:** runaway-script preemption. `JSContextGroupSetExecutionTimeLimit` exists
    in the framework but is private API. Either declare the prototype and accept an
    unsupported dependency, or run scripts in an XPC helper that can be killed —
    heavier, but also a real OS sandbox. Decide when building this, not before.
35. **Themes.** The declarative format table grown in prompt 10 — a template string
    plus a colour per line kind, GUI-DESIGN-NOTES.md §4 — becomes user-editable:
    mIRC's Colors dialog over that one seam, importable/exportable theme files,
    light/dark aware on §5's palettes. The opt-in JS formatting hook lands here,
    beside scripting: computed formatting through the same JavaScriptCore layer,
    documented as slower, never on by default — no JavaScript on the default render
    path. Per-buffer fonts land here too, deferred from §15.5.
36. **Customization.** F-key bindings, arbitrary keyboard shortcuts, and the
    switchbar if the treebar has not settled the need (deferred, not rejected —
    GUI-DESIGN-NOTES.md §2). No toolbar editor: `NSToolbar`'s system customization
    palette already covers it (§8).
37. **User levels.** mIRC's users list with access levels driving script event matching.
38. **Paste protection.** Multi-line paste warning with preview and line count — a
    warning on an already-visible payload, since stage 1 settled that a paste never
    sends and Enter is the only trigger (GUI-DESIGN-NOTES.md §7). The guard this
    adds is against fat-fingering Enter on a large or secret-bearing paste, not the
    only thing between a paste and the wire.
39. **Text niceties.** Spell check, emoji picker, macOS text replacement/services.
40. **Bouncer extras.** The parts left after stage 2 takes `bouncer-networks` and
    `chathistory`: soju's `filehost` (file upload), `metadata`, `search`, and
    `webpush` — the last only matters once there is a mobile companion. Plus ZNC
    compatibility quirks for anyone migrating: `znc.in/self-message`,
    per-network buffers, detach-aware behavior.
41. **History search.** SQLite FTS across all logged history, cross-network, with a
    dedicated search window.

---

## Stage 4 — Polish & release

42. **Accessibility.** VoiceOver over the buffer and nick list — the scrollback is
    the real risk: an `NSTextView` of continuously appended attributed text is where
    an IRC client actually fails screen-reader users (deferred here from
    GUI-DESIGN-NOTES.md §15.6) — keyboard-only operation, high contrast, Dynamic
    Type. §15.6's floor already holds by construction: the grid is a relationship
    between advances so it scales, density presets are multipliers, chrome scales
    independently, and art wraps at large sizes rather than misaligning.
43. **Localization.** String catalogs; RTL layout sanity.
44. **Performance.** 10k+ lines/sec ingest, virtualized scrollback with memory caps,
    instrument the text pipeline.
45. **Diagnostics.** OSLog structured logging, opt-in crash reporting. (The
    raw-traffic debug surface shipped in stage 1: the status window's toggle and the
    Debug & Settings canvas.)
46. **Release engineering.** Distribution is a **Homebrew cask in our own tap**
    (`Lacuna-Research/homebrew-tap`), not the App Store and not homebrew-cask core —
    core has notability requirements a new project will not meet, and a tap is one
    file we control.
    - Signed with a Developer ID and **notarized**. A cask installs into
      `/Applications`, so Gatekeeper quarantines it; without notarization users meet
      "damaged and can't be opened". This needs a paid Apple Developer account, which
      is the real cost of this choice. Notarization also requires the hardened
      runtime, which the app target already sets — inert under ad-hoc signing today,
      live the moment a Developer ID exists.
    - Release artifact: a zipped `Caravan.app` attached to a GitHub release; the cask
      carries the version, URL and SHA-256.
    - A `zap` stanza removing `~/.config/caravan`, `~/.local/share/caravan` and
      `~/.cache/caravan`. Keeping everything under XDG paths makes clean uninstall a
      three-line stanza rather than a scavenger hunt.
    - **No Sparkle.** `brew upgrade` is the update mechanism; shipping a second
      updater that rewrites an app Homebrew believes it manages causes exactly the
      drift Homebrew exists to prevent. Revisit only if direct downloads become a
      channel too.

47. **mIRC import.** Read `mirc.ini`, `servers.ini`, `aliases.ini`, `popups.ini`,
    `remote.ini` — a genuine differentiator for anyone migrating.
48. **Sync.** Optional iCloud settings/server-list sync.
49. **Companion app.** Optional iOS/iPadOS target reusing `IRCProtocol`/`IRCSession`.
50. **Dashboard statistics.** The deferred contents of GUI-DESIGN-NOTES.md §13:
    message counts per channel, ping times per network, a netsplit log, session and
    all-time statistics, possibly a GitHub-style activity graph. The Dashboard
    surface itself ships in stage 2 (Server list — the Dashboard).

---

## Suggested order of attack

Stages 1 and 2 in order; within stage 3, scripting is the long pole and everything
else can be interleaved around it. Items 10, 11, 19, and 20 are what make it *feel*
like mIRC — if you want the vibe early, pull those forward right after stage 1.
