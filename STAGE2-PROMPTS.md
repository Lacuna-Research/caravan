# Stage 2 — The Prompts

**Status:** 11/17 complete. Next: prompt 12.

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

Prompts 1–8 are written out in full. **Prompts 9–17 carry their scope, their grouping and
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

**Status:** complete. Ctrl+O and Ctrl+R ship alongside the four named, being the same
table — without a reset you cannot stop a code. The one thing without a test is that the
colour strip *presents*: `NSPopover` never reports `isShown` in a headless bundle, so it
is checked live instead, and `BUILD-LOG.md` records that.

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

**Status:** complete, with **one outstanding item: the GUI acceptance run**. The machine was
locked throughout, so nothing on screen was confirmed — the Connect sheet's Authentication
section, `TrustSheet`, and the Keychain pre-fill. Everything below the pixels was checked
headlessly against Libera and against a real self-signed TLS handshake; `BUILD-LOG.md`
records exactly what was and was not seen. Stage 1's TLS carry-forward is consumed:
`allowSelfSigned` is gone, replaced by `TLSTrust.trustOnFirstUse`, a `KnownHosts` file and a
trust sheet, and the handshake now fails closed when nobody can be asked.

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

**Status:** complete, with **two outstanding items**. There is no soju to point at, so
bouncer mode is proven against a scripted server that speaks the extension and against the
spec, but not against soju itself — `PLAN.md`'s testing strategy has wanted a local instance
since stage 1 and this is the prompt that needs it. And the machine was locked, so the tree
was not looked at. Direct multi-network *is* verified live: Libera and OFTC at once, each
with its own name, capabilities and selection.

One deviation from the brief, recorded in `BUILD-LOG.md`: **a bouncer keeps a row of its
own**, so the tree is not byte-identical between the two modes. It earns the row —
`BouncerServ` is reachable there — and the networks and their channels *are* identical.

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

**Status:** complete. Every carry-forward note above was consumed and is deleted; what each
turned into is in `BUILD-LOG.md`. `BouncerServ` needs nothing further — the bouncer's control
connection is an ordinary `ConnectionViewModel`, so a `PRIVMSG` from it opens a query like
any other, and `/query BouncerServ` opens one before it has spoken.

**One deviation from mIRC, argued in `BUILD-LOG.md`:** `/msg <nick>` opens the conversation
window. mIRC's does not, but `echo-message` forces it — the server's copy of what we sent
arrives inbound and opens the window regardless, so matching it is the only way the client
behaves the same with the capability and without.

**Verified live against Libera**, including the throttle: twenty requests, five answers.
Fifty at once was not sent and could not be — a public network throttles the *sender* — so
that case is a socket-level test instead.

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

**Status:** complete. Every note above was consumed and is deleted; what each turned into is
in `BUILD-LOG.md`. The one note that was misfiled — a query's missing `chathistory` backfill,
which is prompt 12's — has been moved there rather than deleted.

**Two shortcuts differ from the brief**, both because the live run made them: next-highlight
is ⇧⌥⌘A rather than ⌥⌘H, which is macOS's Hide Others and silently won; and the highlight
state is pink rather than the accent colour, which is grey on a Graphite accent and made the
most important of four states invisible.

**Not verified: the `Bind to ▸ 1…9` submenu itself** — SwiftUI's `.contextMenu` exposes no
accessibility action on a tree row, so it could not be driven. Binding is verified through the
model and the config round-trip, and the digit it produces is verified in the tree.

---

## Prompt 7 — Windows and chrome

**Item:** Multi-window model (second half).

```
Let a buffer leave the window, let the tree be reordered by hand, and give the window
real chrome. GUI-DESIGN-NOTES.md §1, §8, §10 and §12.

The other half of the multi-window model. Prompt 6 was model-and-keyboard work; this is
window-and-chrome work, and they share almost no code.

- One eject affordance, shared by buffers and canvases (§1, §10). A detached window holds
  exactly one buffer and has no tree — "detach this" rather than "open a second copy of
  the app". The tree still lists a detached buffer; selecting its row raises its window
  and says so in the chat area rather than drawing the buffer in two places.
- The Settings & Debug canvas gains its standalone mode from that same affordance, and
  ⌘0 and ⌘, learn to focus that window instead of taking over the chat area.
  `AppModel.showSettingsAndDebug()` is the one place that has to learn the difference.
- Per-window ownership of what prompt 6 hung off `AppModel.selection.didSet`: clearing a
  buffer's activity, marking its unread rule, and pushing its MRU entry. A detached
  buffer is on screen whether or not the main window's selection names it.
- Manual drag-to-reorder within a network, persisted, on top of join order. It has to
  change `ConnectionViewModel.channels`/`.queries` — the property `SidebarTree`,
  `AppModel.allBuffers` and the ⌘K palette all read — or the keyboard and the mouse will
  disagree about where #swift is. §12's channels-before-queries rule survives reordering.
- `NSToolbar` with the system's customization palette rather than a hand-rolled bar (§8),
  visible on first launch with the minimal set §8 names: connection state, sidebar
  toggle, nick-list toggle.
- **The menu bar carries everything the toolbar might not.** §8's other half — "menu bar
  always" — and it is load-bearing the moment the toolbar becomes customizable: prompt
  4's live run found that hiding Connect left multi-network unreachable, and a user who
  drags it out of the toolbar must not be able to reproduce that.

Acceptance: detach a channel and the canvas, watch both keep working while the main
window carries on; reorder a network by hand and confirm the order survives a relaunch
and that ⌘K and next-unread agree with it; drag every item out of the toolbar and
confirm the app is still fully operable from the menu bar.

Do not: the switchbar — still deferred (§2), and revisit only once the treebar is in real
use. No per-window settings; appearance stays global-first.
```

**Status:** complete. All three notes above were consumed and are deleted; what each turned
into is in `BUILD-LOG.md`. `CtrlTabMonitor` needed no change in the end — a detached window
has no tree to walk, so it is installed only by `RootView` and there is never a second one.

**Two departures from the brief**, both made by the live run: the detach shortcut is ⌃⌘O
rather than the obvious ⌃⌘D, which macOS swallows as "Look Up in Dictionary"; and §8's
"minimal default set" is achieved by *declaring* only three toolbar items rather than by
`defaultCustomization(.hidden)`, which macOS 26.5 ignores.

**Not verified: an actual drag, and the customization palette sheet.** System Events cannot
synthesise a drag, and clicking "Customize Toolbar…" through the accessibility API does not
take — the same limitation prompt 6 hit with the `Bind to` submenu. The palette's *presence*
was confirmed by opening the toolbar's context menu; the reorder was verified through the
model and through its load path live.

---

## Prompt 8 — Commands and modes

**Items:** Full command set · Modes.

```
Fill out the command table, and build the mode layer half of it fronts.

Together because `/op`, `/ban`, `/kickban` and `/mode` are one feature seen from two
sides; writing them apart means writing /ban twice.

- The commands: /whois /whowas /who /mode /op /deop /voice /devoice /kick /ban /unban
  /kickban /invite /notice /away /back /list /names /oper /amsg /ame /say /ctcp /ping
  /clear /clearall. `CommandParser` is pure and its switch is the one place that knows
  what a command is — so this is mostly one table and an exhaustive test of it.
- **Every command added to the switch goes in `knownCommands` too**, directly above it.
  That list is what Tab completion offers and nothing fails if you forget.
- Membership modes take a *person*, and several at once: `/op a b c` is one MODE line
  with `MODES=` from ISUPPORT deciding how many changes fit, and the rest on the next.
- `/ban` and `/kickban` want `*!*@host`, which needs the channel roster — so the parser
  says "ban this person from this channel" and the connection, which has the roster,
  resolves the mask. A bare `nick!*@*` is the fallback when the host is not known.
- `/amsg` and `/ame` go to every channel on every connected network. The parser cannot
  know what those are, so the action says "to all channels" and the app expands it.
- Tracked channel modes, and a channel modes sheet to see and set them.
- The list modes — ban `367`/`368`, invite `346`/`347`, except `348`/`349`, and quiet
  where the network has one — as typed events and one list dialog over all of them.
  They are the same numeric shape three times, so they are one dialog with a picker,
  not three dialogs.

Acceptance: op and deop two people at once and watch one MODE line go out; ban someone
by nick and confirm the mask picked up their host; open the ban list on a real channel
and read it; set a channel mode from the sheet and watch the tree and the header agree.

Do not: the *systems* behind three of these commands, which are later prompts and are
deliberately not started here.
  - `/ignore` — the matching machinery is prompt 13's, with the ignore list. Left out of
    the table entirely rather than half-built.
  - `/list` sends LIST and renders the numerics; the channel *browser* is prompt 15.
  - `/away` and `/back` send the command; auto-away, away nick and the away log are
    prompt 14.
  Also not: context menus that invoke these (prompt 9), and no new keyboard shortcuts
  without a live press — this stage has lost two already.
```

**Status:** complete. All five notes above were consumed and are deleted; what each turned
into is in `BUILD-LOG.md`.

**`/ignore` is deliberately not in the table**, and `PLAN.md` item 14 now says so: the
matching machinery belongs with the ignore list in prompt 13, and a half-built `/ignore`
that silently did nothing would be worse than one the server rejects out loud. `/list` and
`/away` ship as the bare commands, with the channel browser (prompt 15) and the away system
(prompt 14) still theirs.

**No new keyboard shortcuts**, on purpose — prompt 7's note asked for a live press per
shortcut and nothing in this prompt is reached for often enough to be worth one. The modes
sheet is a menu item without a key.

**Not verified live: the modes sheet's Add field**, and the invite and except lists — Libera
advertises both, but the test channel had no entries and creating some proves less than the
ban path already did.
---

## Prompt 9 — Things you can do to what is in the buffer

**Items:** Context menus · URL catcher.

```
Right-click, everywhere it means something, and the URL catcher behind the links the
buffer already draws.

Together because they are one question asked of two kinds of target: what can I do with
the thing under the pointer. A nick and a URL are answered by the same hit test, and
writing them apart means writing that test twice.

- **One menu builder, three call sites.** A nick is a nick whether it sits in the nick
  list, in a `<bob>` column in the scrollback, or on a query's tree row. Build the items
  once and have all three ask for them: Whois, Query, Op/Deop, Voice/Devoice, Kick, Ban,
  Kick & Ban, Slap.
- **Every item is a command string through `AppModel.submit`**, not a bespoke call into
  `ConnectionViewModel`. `/whois bob`, `/op bob`, `/kickban bob` — the same path a typed
  line takes. That is what makes stage 3's script-driven version a change to the table
  rather than a rewrite, and what stops the menu and the command drifting apart. Slap
  needs no new command: it is `/me slaps …`, which the table already carries.
- **The scrollback's hit test is already in the text storage.** `LineRenderer` leaves a
  `NickColumn` attribute on every nick column and `applyLinks` leaves a `.link` on every
  URL. An `NSTextView` subclass overriding `menu(for:)` reads what is under the click and
  picks the menu — nick, link, or the channel itself — with no second parser.
- **A command has to know its connection.** `AppModel.submit(_:from:)` resolves one from
  `selection`, which is the *main window's* — so a menu in a detached channel window would
  act on whatever the tree happens to have selected, and the detached input field does
  exactly that today. A live defect on the way past: give `submit` an explicit connection
  and have `ChannelBufferView`, `QueryBufferView` and `StatusBufferView` pass theirs.
- **Operator items are disabled, not absent.** `ChannelModesSheet.canSetModes` already
  makes the "do we hold a prefix" guess; it moves somewhere both call sites can reach it.
- **The URL catcher collects from the `.link` runs of each rendered line as it lands** —
  no second `NSDataDetector` pass over text already scanned — recording the URL, the
  buffer it came from, the sender and the time, capped the way the scrollback is. A sheet
  lists them newest first, scoped to this buffer / this network / everywhere, with Open,
  Copy, Copy All and Open All.
- **Open All asks first above a handful.** Twenty browser tabs from one mis-click is not
  something a client should be able to do without a question.
- Double-clicking a nick in the nick list opens a query; double-clicking a catcher row
  opens the URL.

Acceptance: op, deop, voice and kick a scripted second client from both the nick list and
from its nick in the buffer; slap it; confirm the operator items are disabled when we hold
no prefix; right-click a URL in a real MOTD and open it; open the catcher after a busy
channel has scrolled and copy the lot. Do the last of it in a detached channel window on a
*second* network with the main window pointed at the first — that is the case the
connection fix exists for, and the only one that proves it.

Do not:
  - **Ignore.** The matching machinery is prompt 13's, with the ignore list. A menu item
    that silently did nothing is worse than no item; it arrives with the machinery.
  - **DCC chat/send.** Stage 3, `PLAN.md` item 31 — a transport problem, not a menu one.
  - A reason prompt for Kick and Ban. The default kick reason is an Options setting, and
    Options is prompt 10; until then the parser's default stands.
  - New keyboard shortcuts. This stage has lost two to system bindings that report no
    conflict at build time, and nothing here is reached for often enough to be worth a
    live verification pass.
```

---

## Prompt 10 — Options

**Item:** Options.

```
Turn the one settings form into mIRC's tabbed options, on the Settings & Debug canvas
(§10) rather than in a window of its own.

Two properties of the stage 1 form are requirements rather than accidents, and no tab may
lose them: **every control writes straight through to `caravan.conf`** — no Apply, nothing
to cancel, no pending state to get out of step — and **the file survives being hand
edited**, so a tab that rewrites the whole file rather than the lines it owns is a
regression. `ConfigFile` already behaves; the job is not to regress it, and to have a test
that would notice.

- **A tab exists when it has something in it.** mIRC's eight are Connect, IRC, Display,
  Colors, Sounds, Logging, Mouse and Other. Sounds is prompt 13's and Logging is prompt
  12's; Mouse has one hard-coded behaviour and nothing to set. Build the five that have
  settings behind them and leave notes for the two that will grow one — an empty tab is
  chrome that teaches the user the client is unfinished. A segmented picker like
  `ChannelModesSheet`'s, not a second sidebar; revisit at about seven tabs.
- **Connect is identity, not servers.** The prompt 3 note says the Connect tab inherits
  the sheet's authentication because prompt 11 retires the sheet — but prompt 11 is also
  where the *server list* lands, and authentication is per-server. Split it on that line:
  the nickname, alternate, ident and real name are global and live here; which servers
  exist, their passwords and their SASL method go with the server list. Say so on prompt 11
  so it inherits deliberately rather than by omission.
- **Known hosts get a list and a Forget button.** Today an accepted TLS fingerprint can be
  withdrawn only by hand-editing `$XDG_DATA_HOME/caravan/known_hosts`. `KnownHosts.forget(_:)`
  is written and tested and nothing calls it; a user who accepted the wrong certificate has
  no way back inside the app, which makes this the one genuinely missing safety control.
- **Display carries §15.5's density and zoom.** Density is *line height, not point size* —
  Compact / Normal / Comfortable as multipliers over the user's size, never clamping a
  requested size downward, zero paragraph spacing by default. `ChatFont.paragraphStyle(for:)`
  is where it lands, beside the existing `lineHeightClamp`. Zoom is global: ⌘+, ⌘− and
  actual-size on **⌥⌘0**, because ⌘0 is the canvas.
- **Colours gets the 0–15 grid.** Sixteen swatches, not ninety-nine: §5 puts per-index
  overrides on top of the two 16-colour tables and leaves the extended 16–98 range fixed by
  the specification, so those are not the user's to retune. `Palette.overrides` is carried
  and tested and nothing writes it; persist as one key per overridden index and leave the
  rest absent. Per-*nick* overrides stay out — the affordance for them is "Set Colour…" on
  a nick's context menu, which is prompt 9's `BufferMenu` and stage 3's scripted menus.
- **Whitespace-bearing values use `_` for a space**, as `ChatSettings.encodeSuffix` already
  does for the completion suffixes. Any new setting of that shape takes the same answer
  rather than inventing a second one.

Acceptance: hand-edit `caravan.conf` to carry comments, blank lines and an unknown key,
then change something on every tab and confirm all three survived and only the owned lines
moved. Set a density preset and watch the buffer reflow without the font size changing.
Zoom in and out and back to actual size, **with a live key press for each of the three** —
this stage has lost two shortcuts to system bindings that report no conflict at build
time. Override colour 4 and watch text already on screen change. Accept a certificate,
find the host in the list, forget it, and be asked again on the next connect.

Do not:
  - **§15.3's "Force monospaced grid" toggle**, which this prompt dropped on inspection
    rather than half-build. "Clamp everything, emoji included, to one cell" means owning
    glyph advancement, and TextKit 1 exposes no supported way to set an advance per glyph —
    the honest implementation measures each wide grapheme and applies compensating `.kern`,
    which is a layout subsystem rather than a checkbox. A toggle that only stripped VS16
    would handle §15.3's six-character overlap set and nothing else, while its label
    promised everything. Moved to `PLAN.md` item 18a with the reasoning.
  - The server list, per-server settings, or retiring `ConnectSheet`. Prompt 11.
  - Sounds and Logging tabs. Prompts 13 and 12 bring their own settings and their own tab.
  - Per-window overrides of anything. §15.5's convention is global first, and per-window
    later if wanted — "later" is not this prompt.
  - Themes. The format table is a seam a theme will use; a theme *picker* is stage 3.
```

---

## Prompt 11 — The Dashboard and the server list

**Item:** Server list — the Dashboard.

The Dashboard as a canvas rather than a buffer (§13): a peer row above the networks,
bracketing the tree with Settings & Debug pinned at the bottom. Splash screen and empty
state — first run lands here, no onboarding flow, no wizard. Holds the server list:
groups, per-server nick, password, autojoin channels, perform-on-connect commands,
connect-on-startup, favourites. **Retires `ConnectSheet`**, which is shipped code to
delete rather than a paper plan. Statistics stay deferred to stage 4.

```
Build the app's front door: a server list you keep, on a Dashboard canvas, and the stable
network name that everything else has been waiting for.

**The name is the load-bearing part, and it is settled here.** `PLAN.md`'s "what is a
network's stable, user-facing name?" has been blocking since stage 1 and two families of
`caravan.conf` keys are already written against a placeholder. Get the name right and the
rest of this prompt is a list and a form.

- **Every entry has a `name`: a slug, unique, the user's to edit, and the identifier.**
  Lower-case `[a-z0-9_-]` — **no dots and no slashes**. Slashes because `libera/#swift` is
  the command-line and scripting form (item 34a); dots because both key families put the
  name in the *middle* of a dotted key — `order.<name>.channels` — and a name with a dot
  in it makes that key ambiguous to parse. Derived on creation from the host
  (`irc.libera.chat` → `libera`) or from the bouncer network id, which is already the
  right word, and suffixed `-2` on collision. Editable afterwards.
- **Renaming an entry moves its settings with it.** `binding.N` and
  `order.<name>.{channels,queries}` both key on this, so a rename that left them behind
  would silently break the user's ⌘1–9 and their tree order. One function, two key
  prefixes — the prompt 7 note already says so.
- **Migrate, never drop.** Existing keys hold `host:port` and `host:port[bouncer]`
  (`ConnectionViewModel.networkKey`, `BufferBinding.init(rawValue:)`). On launch, rewrite
  any key in the old form to the entry that matches that host, port and bouncer id — and
  where nothing matches, *create* the entry, so a binding somebody made keeps working and
  the server they made it against appears in the list. `caravan.conf`'s keys are public
  API; dropping one because its format changed is not a migration.
- **The list lives in its own file, `$XDG_CONFIG_HOME/caravan/servers.conf`.** Same format
  and the same `ConfigFile` machinery — write through on change, touch only the lines you
  own — but not the same file: ten entries of eleven fields would bury six settings in a
  file this project promises people will hand-edit. The precedent is `known_hosts`, which
  is separate for the same reason: a list of records has a different shape and a different
  lifecycle from a page of scalars. Keys are `<name>.host`, `<name>.port`, and so on.
- **Per entry:** group, host, port, TLS, nick override, autojoin channels, perform-on-connect
  commands, connect-on-startup, favourite — and the authentication prompt 10 sent here:
  `AuthenticationChoice`, account, certificate label, with **both passwords in the
  `CredentialStore` and never in the file**.
- **The Dashboard is a canvas, a peer row above the networks** (§13), bracketing the tree
  with Settings & Debug pinned below. It is the splash screen and the empty state — first
  run lands here, no wizard. `AppModel.SidebarItem` already spans buffers and canvases, so
  this is a case rather than a new concept, and it inherits detaching for free.
- **`ConnectSheet` is deleted in this prompt**, not deprecated. Two things have to keep
  working first: `ConnectionSettings.lastUsed` still reads `server.host` and `server.port`
  from `caravan.conf`, which every acceptance run since prompt 3 seeds, so **first launch
  with no `servers.conf` but a `server.host` creates an entry from it** — that migrates
  real users and keeps the test harness working with one rule. And the Network menu's
  Connect item points at the Dashboard.

Acceptance: with a hand-written `servers.conf`, connect to two entries and confirm the
tree names them by their slugs. Bind ⌘3 to a channel, quit, relaunch, and confirm it still
works — then *rename* the entry and confirm it still works. Seed the old-format
`binding.3 = irc.libera.chat:6697/#swift` into `caravan.conf`, launch, and watch it migrate
to the slug with the binding intact and an entry appear in the list. Add a server through
the Dashboard, set an autojoin channel and a perform line, connect, and watch both happen.
Delete `ConnectSheet.swift` and confirm nothing references it.

Do not:
  - **Statistics, ping times, netsplit logs, activity graphs.** §13 calls them "way down
    the road" by name and stage 4 owns them. The part that matters now is the list.
  - A connection *manager* — retry policy, connect-all, ordering of startup connections
    beyond "connect these on startup". Flood protection is prompt 16.
  - Reserved shortcuts. §13: the Dashboard is reachable from the tree and needs no key.
  - Per-server appearance overrides. §15.5's global-first convention still holds.
```

---

## Prompt 12 — Logging

**Item:** Logging.

Per-network and per-channel plain-text logs in mIRC's layout, a log viewer, and "reload
last N lines on join" so windows are not empty after a reconnect. The hard part is
reconciling with `chathistory`: against a bouncer the server backfills the same period the
local log already covers, so the buffer needs de-duplication by message id or
`server-time` rather than blind concatenation. Prompt 4 is what makes that testable.

*To be written out before it starts.*

**Carry-forward** *(consumed when this prompt runs)*

- From prompt 3: **the `msgid` you will de-duplicate on is already in hand.**
  `IRCEvent.message` carries the whole `IRCTags` section, so `tags.value(for: "msgid")` needs
  nothing new from the session — and `ConnectionViewModel.parseServerTime` already turns the
  `time` tag into a `Date` for the fallback comparison.
- From prompt 4: **tags are still carried by `IRCEvent.message` and nothing else**, and this
  is the prompt where that stops being enough. Prompt 4 left it deliberately: soju's
  `chathistory` replays messages, so the general case would have been built for events soju
  does not send. A local log holds joins, parts and topic changes too, and reconciling those
  against a replay needs their `time` and `msgid` as much as a message's. Either add `tags`
  to the replayed cases or give every event a common envelope — the envelope is the larger
  change and by now probably the right one.
- From prompt 10: **the Logging tab is yours to add.** Options built five of mIRC's eight
  tabs and deliberately skipped this one rather than shipping it empty. Adding it is one
  case in `OptionsPane.Tab` in `SettingsDebugCanvas.swift` plus a `@ViewBuilder` pane; the
  enum is `CaseIterable` and drives the picker, so there is nothing else to wire. Whatever
  it holds — log directory, what to log, reload-last-N — writes through `ChatSettings` on
  change like every other control, with no Apply button.
- From prompt 4: `CHATHISTORY LATEST <target> * <limit>` fires on our own `JOIN`, in
  `IRCSession.requestHistoryIfOurJoin`, with the count in
  `SessionConfiguration.chatHistoryLimit`. De-duplication wants `BEFORE`/`AFTER` against the
  newest line already in the log instead, which is the same function with a different
  selector — the request site is already in one place.
- From prompt 5: **a query has no `chathistory` backfill at all.**
  `IRCSession.requestHistoryIfOurJoin` fires on our own `JOIN` only, so a conversation
  reattached through a bouncer opens empty where a channel opens mid-conversation. Opening
  a query is a client-side act with no wire event to hang a `CHATHISTORY LATEST` off; the
  natural hook is `ConnectionViewModel.openQuery(with:)`.

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

**Carry-forward** *(consumed when this prompt runs)*

- From prompt 6: **the one highlight rule that exists is `BufferActivity.mentions(_:in:)`** —
  own nick, matched as a word rather than a substring, so `bobbins` does not mention `bob`.
  The keyword and regex lists replace that function rather than sitting beside it, and
  `BufferActivity.caused(by:ownNick:isConversation:)` is the pure table they plug into. It
  takes the nick as a parameter precisely so it never had to reach for app state.
- From prompt 6: **a private message is currently hard-coded to `.highlight`**, on §18's
  grounds that highlights and private messages are the two default triggers. That is a
  reasonable default and a poor permanent rule — it is the first thing that should become a
  setting here, and `isConversation` is the flag it already keys off.
- From prompt 6: **an ignore has to suppress the activity state, not just the line.** A
  buffer that goes pink for a message you never see is worse than no ignore at all. Both
  happen in `ConnectionViewModel.append(_:)`, a few lines apart — the line goes to
  `destinations(for:)` and the state to `raise(_:to:)`.
- From prompt 9: **the Ignore menu item is this prompt's to add**, and its slot is already
  shaped. `BufferMenu.nickItems(_:channel:canSetModes:)` in `Sources/CaravanUI/BufferMenu.swift`
  builds the groups; Ignore belongs in the third group beside Kick and Ban, as
  `BufferMenuItem("Ignore", .command("/ignore \(nick)"))` — enabled unconditionally, since
  ignoring somebody needs no prefix. Prompt 9 left it out rather than shipping an item that
  silently did nothing. Nothing else has to change: every item is a command string, so the
  item works the moment `/ignore` is in `CommandParser`'s switch (and its `knownCommands`).
  `Tests/CaravanUITests/BufferActionsTests.swift` asserts the exact command strings and the
  exact enabled set, so both tests need the new item adding — which is the point of their
  being exhaustive.
- From prompt 10: **the Sounds tab is yours to add**, and so is whatever Highlights needs.
  Options built five of mIRC's eight tabs and skipped Sounds rather than ship it empty;
  adding one is a case in `OptionsPane.Tab` in `SettingsDebugCanvas.swift` and a
  `@ViewBuilder` pane, since the enum is `CaseIterable` and drives the picker. The
  keyword and regex lists are the first setting here that is a *list* rather than a scalar,
  which `caravan.conf`'s one-value-per-key format does not hold directly — decide the
  encoding deliberately, and note that `ChatSettings.encodeSuffix`'s `_`-for-space trick is
  the precedent for values the format cannot carry verbatim.
- From prompt 9: **the catcher's line-by-line seam is where ignore has to bite too.**
  `ConnectionViewModel.append(_:)` now calls `urlCatcher?.record(...)` in the same loop that
  appends the line and raises the activity. An ignored message must not put its links in the
  URL catcher either — a third thing to suppress, in the same three lines.

---

## Prompt 14 — Presence

**Items:** Notify list · Away system.

`MONITOR` where available with `ISON` polling as the fallback, online/offline events, a
notify window and sounds. Plus `/away`, auto-away on idle, an optional away nick, and an
away log capturing what arrived while you were gone.

Together because both answer "who is around" — one about other people, one about you —
and both hang off the same presence events.

*To be written out before it starts.*

**Carry-forward** *(consumed when this prompt runs)*

- From prompt 3: **`away-notify` and `account-notify` are negotiated and tracked already.**
  `Member.isAway`, `.account` and `.realName` are on the channel snapshot and maintained by
  `ChannelRoster.edit(nick:_:)`, so a nick list that dims away members needs no protocol
  work — only a renderer that reads the flag. The trap is the opposite direction: `isAway`
  is `false` both for "present" and for "this server does not offer the capability", so
  anything drawing absence as presence must first check
  `NegotiatedCapabilities.isEnabled(.awayNotify)`.
- From prompt 3: `/away` has to reach `CommandParser.knownCommands` as well as its switch —
  the same trap prompt 8 carries.

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
- From prompt 5: **there is already one outbound rate limit, and it is not this one.**
  `CTCPThrottle` in `IRCSession` bounds *auto-replies* — burst 5, one token back every 5s,
  one bucket per connection — because a CTCP flood would otherwise make the client an
  amplifier. It is a policy about answering strangers; this prompt's is a policy about not
  tripping `Excess Flood` on what the user typed. **Decide explicitly whether they compose
  or the CTCP bucket folds into the general limiter**, and say which in `BUILD-LOG.md`: two
  limiters silently queueing behind each other is the kind of thing that shows up as
  "replies stopped and nobody knows why". The live run measured the real constraint —
  Libera throttles the *sender*, answering twenty rapid `PRIVMSG`s with `*** Message to
  <nick> throttled due to flooding` — so the outbound limit has a number to aim at.

---

## Prompt 17 — Buffer utilities

**Item:** Buffer utilities.

⌘F find-in-buffer with highlight, and copy with and without formatting. Last because
"copy without formatting" is not answerable until there is formatting to strip, and
find-in-buffer wants the scrollback to have stopped changing shape.

*To be written out before it starts.*

---

**Stage 2 is done when** you would use this instead of your current client.
