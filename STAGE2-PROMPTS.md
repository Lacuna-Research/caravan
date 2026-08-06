# Stage 2 — The Prompts

**Status:** 1/17 complete. Next: prompt 2.

Stage 2's work queue. Every numbered item in `PLAN.md`'s stage 2 is attached to exactly
one prompt here; a few prompts carry two or three items, and the largest item is split
across two. The grouping is by **shared seam**, not by theme — two items belong together
when they touch the same code, and apart when they merely sound related.

Each block is self-contained and assumes the previous ones are done and merged. Every
prompt has a **Do not** section: the scope fence that keeps later work from leaking
backward. Standing rules — Swift 6 strict concurrency, macOS 15, swift-testing, zero
warnings, zero external dependencies — live in `CLAUDE.md` and load automatically.

Each prompt is one branch (`prompt-NN-slug`), one PR, squash-merged once CI is green.
Bump the **Status** line above in the same PR; `make check` fails if it is missing or
malformed.

### Prompts are written just-in-time, and that is deliberate

Prompts 1–6 are written out in full. **Prompts 7–17 carry their scope, their grouping and
their fence, but not yet their detail** — and are to be fleshed out immediately before
they start, not now.

Stage 1 taught this twice. Writing a detailed brief for work that six intervening prompts
will have reshaped produces a brief that is confidently wrong, and a wrong brief is worse
than a thin one because it is followed. The `PLAN.md` items behind these are the durable
statement of intent; a prompt is the short-lived working document that turns one into a
session. Reorder, rescope and merge these freely as the stage teaches you things — that is
what `BUILD-LOG.md` preserves the history for.

### Carry-forward notes

Same convention as stage 1: a note goes on the prompt that needs it, under a
`### Carry-forward` heading, naming the file and the symbol. A note that says "think about
X" is worth little; one that names the seam is worth a session. Notes are **deleted when
the prompt that received them runs**, and `make check` fails if one outlives its prompt.

Notes aimed past this stage go on the `PLAN.md` item instead.

---

## Prompt 1 — Formatting codes: rendering

**Item:** mIRC formatting codes — rendering.

```
Parse and render mIRC's inline formatting: bold, italic, underline, strikethrough,
monospace, reverse, reset, and ^C colours including the extended 16–98 palette.

- A pure IRCFormat module, in the Linux job beside IRCProtocol: the code table and the
  colour tables are tables, and a colour table exercised only through a text view is one
  nobody exercises. Colours come out as *indices*; which red index 4 is belongs to the
  window, not to the parser.
- Palettes per GUI-DESIGN-NOTES.md §5: a three-state Auto / Light / Dark toggle, Auto
  following the system appearance; a full alternate 16-colour palette for dark
  backgrounds — not a 0↔1 swap, since the other fourteen are still tuned for white; the
  fixed 16–98 range unchanged; and per-index user overrides on top.
- Nick colourisation per §6: hash seeded on the nick alone, not nick + network, so bob
  looks like bob however you reach him. Manual per-nick override. The palette
  contrast-checked against *both* backgrounds, so it cannot be a naive hue wheel.
- Nick colour applies only where there is a nick *column*. An event line names people
  mid-sentence, and colouring those turns the event stream into a ransom note.

Acceptance: paste a line carrying every code into a channel and read it back correctly;
switch the palette between light and dark and watch the same line stay legible; confirm
no control character ever reaches the buffer.

Do not: the input box. Writing codes is prompt 2 — reading and writing share only the
code table, and a client that writes codes it cannot read is the wrong way round.
```

**Status:** complete. Per-index and per-nick overrides ship without UI — `Palette` carries
both and both are tested, but a 99-swatch grid belongs in stage 3's Colors dialog rather
than bolted onto a settings list. Recorded on that `PLAN.md` item.

---

## Prompt 2 — The input field grows up

**Items:** mIRC formatting codes — authoring · Tab completion.

```
Make the input box author what prompt 1 taught the buffer to read, and complete what you
are typing.

These are one prompt because they are one seam: InputTextView.doCommand(by:), which
prompt 9 of stage 1 already built to intercept Return and the arrow keys. Tab arrives
there as insertTab:, and so do the control-key chords. Two prompts would touch the same
forty lines twice.

- Ctrl+K, Ctrl+B, Ctrl+U, Ctrl+I insert the control characters IRCFormatting already
  names. Ctrl+K with no argument opens a colour picker strip; with digits typed after it,
  it takes them as the index, which is what mIRC does and what muscle memory expects.
- The input box renders what it is about to send, using the same renderer the buffer
  uses. If what you type does not look like what you send, the codes are unusable.
- Tab completion, mIRC-style cycling: nick completion with a configurable suffix (": "
  at line start, " " elsewhere), plus channel and command completion. The nick list to
  complete against is on the buffer's Channel snapshot, already ordered; the command
  names are the switch in CommandParser, which is the one place that knows them.
- Repeated Tab cycles; Shift+Tab cycles backwards; anything else commits the completion.

Acceptance: compose a line with bold, a colour and a nick completion in it, send it, and
have it come back looking the way it looked while you were typing.

Do not: aliases or scripting — a Ctrl+K that runs a script is stage 3. No completion of
anything that requires a network round trip.
```

**Carry-forward** *(consumed when this prompt runs)*

- From prompt 1: `IRCFormatting` names every control character and `InlineStyle` models
  every switch, so authoring is inserting characters the parser already round-trips.
  `IRCFormatting.parse` on the input box's own text gives the preview for free.
- From prompt 1, and this cost the whole item once: **styling dies silently at the
  crossing into an `NSTextView`, in two different ways.** `NSAttributedString(_:including:)`
  carries the named scope and nothing else — `AttributeScopes.CaravanAttributes` now nests
  `AppKitAttributes` for exactly this reason — and a bare `.single` on `underlineStyle` or
  `strikethroughStyle` resolves to SwiftUI's `Text.LineStyle`, which has no
  `NSAttributedString` key at all. `LineRenderer.singleLine` is the typed constant that
  avoids the second. The input box's preview draws through an `NSTextView` too, so assert
  the *storage* rather than the `AttributedString`: `stylingReachesTheTextView` in
  `InlineFormattingTests` is the shape to copy.
- From prompt 1: the colour strip's swatches should come from `MIRCPalette` through
  `Palette.colours`, not a second table. Note they may be appearance-resolving `NSColor`s,
  so a swatch compares equal to a plain colour only after resolving — `drawn(_:in:)` in
  `InlineFormattingTests` is the helper for that.

---

## Prompt 3 — Capabilities and authentication

**Items:** IRCv3 capabilities (the standard set) · Authentication.

```
Negotiate capabilities properly, and log in.

Together because SASL *is* a capability: it rides on CAP LS/REQ/END, and splitting them
means building the negotiation state machine twice.

- CAP negotiation with cap-notify, multi-prefix, away-notify, account-notify,
  extended-join, userhost-in-names, server-time, message-tags, echo-message, batch,
  chghost, invite-notify, setname, standard-replies, labeled-response.
- echo-message is the one with a waiting consequence: stage 1 echoes our own messages
  locally and marks them with LineKind.isSelfEcho precisely so this prompt can suppress
  the duplicate. That is a filter, not an archaeology project — use it.
- server-time rewrites what a timestamp means: a replayed line carries the time it was
  said, not the time it arrived. RenderContext.now is where that lands.
- SASL PLAIN, EXTERNAL (CertFP) and SCRAM-SHA-256. NickServ auto-identify as the
  fallback, redacted on the way into the trace like every other credential.
- Every secret in the Keychain, never in caravan.conf. This is the prompt that makes the
  Connect sheet's password field stop being re-typed every session.

Acceptance: connect to Libera with SASL and with NickServ; confirm the trace shows
AUTHENTICATE redacted; confirm your own messages appear exactly once with echo-message
negotiated and exactly once without.

Do not: bouncer-networks or chathistory — prompt 4 owns both, because they change how
buffers are populated rather than how a connection is established.
```

**Carry-forward** *(consumed when this prompt runs)*

- From stage 1 prompt 4: TLS self-signed acceptance still has no user-facing trust
  decision. `IRCConnection` records subject and SHA-256 fingerprint in
  `acceptedCertificate` and logs loudly when trust was not established, but with no UI to
  ask, `allowSelfSigned: true` still accepts. Turn that into trust-on-first-use here,
  beside CertFP, since both are about which certificate you believe.

---

## Prompt 4 — Multi-network, and the bouncer

**Items:** Multi-network · IRCv3 capabilities (`soju.im/bouncer-networks`,
`draft/chathistory`).

```
Two networks at once, and one bouncer pretending to be several.

Together because bouncer mode *is* bouncer-networks: writing multi-network without it
means writing the sidebar model twice, once per shape.

- Two modes behind one sidebar model. Direct: one TCP connection per network with
  independent state, nick and identity. Bouncer: a single connection to soju where
  soju.im/bouncer-networks enumerates the upstream networks. The UI must not care which
  is in play — that is the whole test of the design.
- The fallback for the bouncer case is one connection per network with the network in
  the username (<user>/<network>), which is also how a stage-1 client reaches soju.
- draft/chathistory to backfill what was missed while detached.
- BouncerServ needs nothing special: it is a query window.

Acceptance: connect to two real networks at once and hold a conversation in a channel on
each; then reach the same two through soju and confirm the tree looks identical.

Do not: logging. Prompt 12 owns the interaction between chathistory and the local log —
it is a de-duplication problem, and it wants both halves to exist first.
```

**Carry-forward** *(consumed when this prompt runs)*

- From stage 1 prompt 8: the tree is a `List` of one `DisclosureGroup` per connection.
  Rolled-up activity and a second network both need the expansion state to move off
  `AppModel.isNetworkExpanded` — one flag for one network — and onto the connection.

---

## Prompt 5 — Queries and CTCP

**Item:** Queries & CTCP.

```
Private messages get their own windows, and CTCP stops rendering as control characters.

- Query buffers, sorted after channels in the same per-network list, bullet sigil, per
  GUI-DESIGN-NOTES.md §12. Each with its header band showing conversational context —
  first and last message and similar (§14).
- VERSION, PING, TIME, USERINFO, CLIENTINFO, FINGER and ACTION handled and replied to,
  with reply throttling. A CTCP flood must not turn the client into an amplifier.

Acceptance: hold a PM conversation in its own window; receive a CTCP VERSION and watch
it answer once; receive fifty and watch it answer far fewer.

Do not: DCC. CHAT and SEND are stage 3, and they are a transport problem rather than a
message-handling one.
```

**Carry-forward** *(consumed when this prompt runs)*

- From stage 1 prompt 6: `ACTION` is already unwrapped — `IRCEvent.message` carries
  `isAction` with the `\u{01}` wrapper stripped. Every *other* CTCP still arrives as an
  ordinary message with its delimiters intact, so a `VERSION` request currently renders as
  control characters in a channel window. `EventTranslator.unwrapAction` is where the
  general version belongs.
- From stage 1 prompt 8: the tree, the buffer and the selection are all channel-shaped.
  `ChannelBuffer` wraps a `Channel`, `AppModel.SidebarItem` has `.status` and `.channel`,
  and `ConnectionViewModel.destinations(for:)` routes a message at a nick to the status
  window. A query is a third case in each of those three, and the sort-after-channels rule
  is the ordering of one array.
- From stage 1 prompt 8: `HeaderBand` is general and already built — never hidden,
  shrink-to-two-lines, expand-into-a-scroller. The query case is content, not behaviour.
- From stage 1 prompt 11: an outgoing `/msg bob hi` typed in a channel echoes *there* as
  `-> *bob* hi`, deliberately marked as leaving the window. Query buffers change where
  that echo goes, not how it reads: a message to a window that *is* the query renders
  `<you> hi`, and the `-> *nick*` form stays for messages aimed elsewhere. `LineKind
  .ownPrivateMessage`/`.ownPrivateNotice` and `ConnectionViewModel.isThisWindow` are the
  two places.

---

## Prompt 6 — Activity and navigation at scale

**Item:** Multi-window model (first half).

```
Make thirty buffers navigable. GUI-DESIGN-NOTES.md §3, §9 and §11.

Split from the second half because this is model-and-keyboard work and that is
window-and-chrome work; they share almost no code, and together they are three sessions.

- Per-buffer activity: mIRC's four colour-coded states — normal, activity, message,
  highlight — with badges only for highlights. Collapsed network groups roll up the
  highest-severity state of their hidden children; jumping to a hidden buffer
  auto-expands and reveals it.
- Next-unread and next-highlight as two *separate* bindings, not one. Between them they
  are the highest-frequency navigation action in daily use.
- Ctrl+Tab in MRU order — the Windows Alt-Tab model, tap to toggle the last two, hold and
  keep tapping to walk back — not Chrome's positional order.
- A ⌘K fuzzy quick-switcher over buffer names across every network. Names only; ⌘F
  in-buffer and history search stay separate features.
- ⌘1–9 buffer bindings (§11): nothing bound by default; assigned from the tree row's
  context menu (Bind to ▸ 1…9, taken digits shown); the digit shown in the tree; nine
  global slots, not nine per network; a binding attaches to buffer identity (network +
  buffer name), survives restarts in caravan.conf, and never reorders the tree.
  Activating a binding whose target is not open opens it, auto-joining only if the
  network is already connected. ⌘0 stays reserved for Settings & Debug.

Acceptance: sit in thirty buffers across two networks, collapsed, and reach any of them
without the mouse.

Do not: detaching windows, reordering, or the toolbar — prompt 7. The switchbar stays
deferred (§2): revisit once the treebar is in real use.
```

---

## Prompt 7 — Windows and chrome

**Item:** Multi-window model (second half).

Detachable windows, sharing **one** eject affordance between buffers and canvases (§1,
§10) — this is where the Settings & Debug canvas gains its standalone mode, and where ⌘0
and ⌘, learn to focus that window instead of taking over the chat area. Manual
drag-to-reorder within a network, persisted, on top of join order. `NSToolbar` rather than
a hand-rolled bar (§8).

*To be written out before it starts.*

---

## Prompt 8 — Commands and modes

**Items:** Full command set · Modes.

The command table filled out — `/whois /whowas /who /mode /op /deop /voice /devoice
/kick /ban /unban /kickban /topic /invite /notice /away /back /list /names /ignore /oper
/server /disconnect /amsg /ame /say /ctcp /ping /clear /clearall` — and the mode work
underneath the half of them that sets modes: readable mode-change rendering, tracked
channel modes, and the ban/quiet/invex list dialogs (`367`/`368`, `346`–`349`).

Together because half the command table is a thin front for the mode layer, and writing
them apart means writing `/ban` twice.

*To be written out before it starts.*

---

## Prompt 9 — Things you can do to what is in the buffer

**Items:** Context menus · URL catcher.

Nick-list and channel right-click menus — whois, query, op/deop, voice, kick, ban,
kickban, ignore, DCC chat/send, slap — hard-coded now and script-driven in stage 3. Plus
clickable links, a URL history window, and copy/open-all.

Together because they are one question asked of two kinds of target: what can I do with
the thing under the pointer.

*To be written out before it starts.*

---

## Prompt 10 — Options

**Item:** Options.

mIRC-shaped tabbed prefs — Connect, IRC, Display, Colors, Sounds, Logging, Mouse, Other —
built out on the Settings & Debug canvas rather than in a separate window (§10). Two
properties of the stage 1 form are requirements, not accidents: every control writes
straight through to `caravan.conf` with no Apply button and nothing to cancel, and the
file survives being hand-edited. Display carries the density and zoom model from §15.5.

*To be written out before it starts.*

**Carry-forward** *(consumed when this prompt runs)*

- From prompt 1: the Colours tab already has rows to absorb — a Palette segmented control
  and a "Colour nicknames" toggle, in `SettingsDebugCanvas`'s `SettingsPane`, backed by
  `ChatSettings.paletteMode` and `.coloursNicks`. What it does *not* have is the per-index
  and per-nick override UI §5 and §6 ask for; `Palette.overrides` and `.nickOverrides` are
  carried and tested but nothing writes them, and `ChatSettings` does not persist them.
  Whether that grid lands here or waits for stage 3's Colors dialog is this prompt's call —
  the stage 3 item records the persistence question either way.

---

## Prompt 11 — The Dashboard and the server list

**Item:** Server list — the Dashboard.

The Dashboard as a canvas rather than a buffer (§13): a peer row above the networks,
bracketing the tree with Settings & Debug pinned at the bottom. Splash screen and empty
state — first run lands here, no onboarding flow, no wizard. Holds the server list:
groups, per-server nick, password, autojoin channels, perform-on-connect commands,
connect-on-startup, favourites. **Retires `ConnectSheet`**, which is shipped code to
delete rather than a paper plan. Statistics stay deferred to stage 4.

*To be written out before it starts.*

---

## Prompt 12 — Logging

**Item:** Logging.

Per-network and per-channel plain-text logs in mIRC's layout, a log viewer, and "reload
last N lines on join" so windows are not empty after a reconnect. The hard part is
reconciling with `chathistory`: against a bouncer the server backfills the same period the
local log already covers, so the buffer needs de-duplication by message id or
`server-time` rather than blind concatenation. Prompt 4 is what makes that testable.

*To be written out before it starts.*

---

## Prompt 13 — What deserves attention, and what deserves none

**Items:** Highlights & notifications · Ignore list.

Nick mention, custom keyword and regex lists, per-window and per-event sounds, macOS
notifications, Dock badge, menu-bar item — the dedicated notifications interface deferred
from §18, with highlights and private messages as the out-of-the-box triggers. And
wildcard `nick!user@host` ignore masks with mIRC's level flags (`-pcntikm`) and temporary
ignores with a duration.

Together because they are the same matching machinery pointed in opposite directions: one
decides what is worth interrupting you for, the other what is not worth showing at all.

*To be written out before it starts.*

---

## Prompt 14 — Presence

**Items:** Notify list · Away system.

`MONITOR` where available with `ISON` polling as the fallback, online/offline events, a
notify window and sounds. Plus `/away`, auto-away on idle, an optional away nick, and an
away log capturing what arrived while you were gone.

Together because both answer "who is around" — one about other people, one about you —
and both hang off the same presence events.

*To be written out before it starts.*

---

## Prompt 15 — Channel list

**Item:** Channel list window.

`/list` with min and max user filters, name and topic search, sortable columns, and
join-on-double-click. A canvas rather than a buffer, and the first surface that has to
stay responsive while tens of thousands of rows arrive.

*To be written out before it starts.*

---

## Prompt 16 — Flood protection

**Item:** Flood protection.

Outbound send-rate throttling to avoid `Excess Flood`, and inbound flood detection with
auto-ignore.

*To be written out before it starts.*

**Carry-forward** *(consumed when this prompt runs)*

- From stage 1 prompt 5: a server `ERROR` currently schedules a reconnect like any other
  failure, on the grounds that most are transient ("Closing link: ping timeout") and
  staying dead after one is worse. But a K-line or a throttle also arrives as `ERROR`, and
  reconnecting into one is exactly the antisocial behaviour this prompt exists to prevent.
  The backoff ceiling bounds it; recognising the permanent cases would be better. The
  signal is available: an `ERROR` arriving *before* 001 is far more likely to be a ban or
  a throttle than a dropped link.

---

## Prompt 17 — Buffer utilities

**Item:** Buffer utilities.

⌘F find-in-buffer with highlight, and copy with and without formatting. Last because
"copy without formatting" is not answerable until there is formatting to strip, and
find-in-buffer wants the scrollback to have stopped changing shape.

*To be written out before it starts.*

---

**Stage 2 is done when** you would use this instead of your current client.
