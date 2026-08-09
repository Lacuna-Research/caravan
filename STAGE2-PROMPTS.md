# Stage 2 — The Prompts

**Status:** 15/18 complete. Next: prompt 15.

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
  - `/ignore` — the matching machinery is prompt 13a's, with the ignore list. Left out of
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
matching machinery belongs with the ignore list in prompt 13a, and a half-built `/ignore`
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
  - **Ignore.** The matching machinery is prompt 13a's, with the ignore list. A menu item
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
  Colors, Sounds, Logging, Mouse and Other. Sounds is prompt 13b's and Logging is prompt
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

```
Write the conversation down, put it back on screen when a window opens, and make sure the
bouncer's copy of the same hour does not arrive as a second copy.

**The whole prompt turns on one decision: what a log line is keyed by.** Get that right and
reload, de-duplication and the viewer are all consequences of it; get it wrong and every
reattach shows the last twenty minutes twice.

- **A log line carries its own full timestamp — `[yyyy-MM-dd HH:mm:ss]`.** This is the one
  deliberate departure from mIRC, whose lines carry `[HH:mm:ss]` and leave the date to a
  `Session Start:` banner. A date recoverable only by scanning backwards for a banner cannot
  be compared against a replayed line's `server-time`, and that comparison is the point of
  the item. Everything else is mIRC's: plain text, the stock `LineFormatTable.mIRC`
  sentences, control codes stripped.
- **The log is rendered canonically, never from the user's settings.** `chat.timestamp-format`
  is a *display* setting; a log whose shape changes when somebody previews a timestamp format
  is a log nothing can parse. `LineRenderer.describe` already turns an event into a kind and
  its fields — give it a plain-text sibling that expands the same template with the canonical
  stamp and no attributes, no palette and **no `NSDataDetector` pass**. Rendering every line
  twice on the ingest path is the one performance trap here.
- **`$XDG_DATA_HOME/caravan/logs/<network>/<buffer>.log`**, appended, one file per buffer.
  `<network>` is the prompt 11 slug, which is already `[a-z0-9_-]`; `<buffer>` is a channel
  name or a nick and is *not* safe — percent-escape the path separators rather than trusting
  it. Not the config directory: a log is data, and `known_hosts` set that precedent.
- **De-duplication is a per-buffer index of keys, consulted by every arriving message.** The
  key is the `msgid` where there is one, and `(timestamp to the second, nick, text)` where
  there is not — the second form is what a *log* line can offer, since a plain-text log has
  nowhere to put a message id and inventing a sidecar to hold one would make the file no
  longer plain text. Because the fallback key carries the full date, a false positive needs
  the same person to say the same words in the same second, which is the definition of the
  duplicate we are removing. Seed the index from the replayed tail *and* from every line
  appended live, and consume a key on a hit so that something genuinely said twice appears
  twice.
- **A suppressed line is suppressed everywhere.** It must not raise the activity state and
  must not reach the URL catcher — the same three seams prompt 13a inherits, all in
  `ConnectionViewModel.append(_:)`.
- **Replayed lines are dimmed.** They are the past, they came from a file rather than from
  the network, and the boundary where dimming stops is what tells a user where the live
  conversation begins. No banner line; the dimming is the signal.
- **A query gets its backfill here too**, per the prompt 5 note: `openQuery(with:)` asks for
  `CHATHISTORY LATEST` when it has just created the buffer, which needs one public method on
  `IRCSession` beside `requestHistoryIfOurJoin`.
- **The Logging tab is a case in `OptionsPane.Tab` and a pane**: what to log, how many lines
  to reload, the directory with a reveal button, and the way into the viewer. Write-through
  on change like every other control.
- **The viewer reads the same files, not a second store.** Networks and buffers from a
  directory scan, the tail of the selected log, a filter field, Reveal in Finder. Opened
  from the Logging tab and from a buffer's context menu.

Acceptance: against a real bouncer, join a channel, say something, quit the app, relaunch and
confirm the window opens with the log's tail dimmed above the live line — and that the
bouncer's `CHATHISTORY` replay of the same period adds nothing you can already see. Do it
again with logging off and confirm the replay is the only source. Say the same word twice in
one second and confirm both survive. Log a channel whose name would be a path if you took it
literally. Turn the reload count to zero and confirm windows open empty.

Do not:
  - **A common envelope over `IRCEvent`, or `tags` on the replayed cases.** The prompt 4 note
    offers both; measure the need before paying for either. See the note's disposition below.
  - **`CHATHISTORY BEFORE`/`AFTER` against the newest logged line.** Also prompt 4's note, and
    also to be decided on the evidence rather than inherited.
  - **SQLite, full-text search, or a scrollback database.** `PLAN.md`'s architecture table
    lists both plain-text logs and SQLite; this item is the plain-text half, and search over
    logs is a filter field over a file, not an index.
  - **Log rotation, compression, retention policies.** No user has asked and no file is large
    yet. `PLAN.md` is where that goes if it ever does.
  - **Logging raw wire traffic.** That is `/debug` and `TraceFileWriter`, it is redacted on a
    different seam, and merging the two would put a `PASS` in a chat log.
  - **Highlights, sounds, notifications.** Prompt 13b, even though a log line and a highlight
    read the same `append(_:)` seam.
```

**Status:** complete. All five notes above were consumed and are deleted; what each turned
into is in `BUILD-LOG.md`.

**Two of the five were answered "no", and that is the substantive result.** Prompt 4 left
this prompt a choice between adding `tags` to the replayed event cases and giving every
`IRCEvent` a common envelope, and separately asked for `CHATHISTORY BEFORE`/`AFTER` against
the newest logged line. Neither is built, and neither is deferred — both were measured and
declined, with the reasoning in `BUILD-LOG.md`. In short: `chathistory` is *message*
history, so a logged join has nothing to collide with and the envelope would have been
built for traffic that never arrives; and `LATEST <limit>` is bounded where `AFTER <a month
ago>` is not, so the bounded overlap plus a de-duplication index beats the unbounded
request that was supposed to avoid it.

**The one departure from mIRC's log format is the stamp**: `[yyyy-MM-dd HH:mm:ss]` per line
rather than `[HH:mm:ss]` plus a `Session Start:` banner, because a date recoverable only by
scanning backwards for a banner cannot be compared against a replayed line's `server-time`.

**The live run found a defect in prompt 11's code, not in this one**: `connectStartupServers()`
had no caller anywhere, so `connect-on-startup` shipped doing nothing. Fixed here with a
`.task` on `RootView` and pinned by `ServerConnectingTests.startupServersConnect`.

**Not verified live: de-duplication against a real bouncer** — there is still no soju to
point at, which is the acceptance `PLAN.md`'s "Where does a soju come from?" has blocked
since stage 1; it was driven against a scripted server instead. Nor our own outbound line
reaching the log, because synthetic keystrokes would not land in the chat input; that path
has an end-to-end test through the real `send()`. The live run covered writing, the reload,
the Logging tab and the viewer.

---

## Prompt 13a — What deserves none

**Item:** Ignore list.

Wildcard `nick!user@host` masks with mIRC's level flags (`-pcntikm`), temporary ignores
with a duration, and the `/ignore` command that fronts them.

**Split from a combined prompt 13**, which paired this with highlights on the grounds that
they are "the same matching machinery pointed in opposite directions". They are not, quite:
highlights match *message text* against keywords and patterns, ignores match *senders*
against `nick!user@host` masks, and `IRCMask` already exists for the second. What they
genuinely share is one seam — `ConnectionViewModel.append(_:)` — and that is a few lines,
not a prompt's worth of common ground.

**This half goes first, and the ordering is the reason.** An ignored line must never reach
the highlight rules, so whichever lands second inherits the other's suppression points. If
highlights ship first they add a fourth thing for ignore to suppress; if ignore ships first
the highlight rules simply never see a suppressed line. One order costs nothing and the
other costs a note nobody reads until it is wrong.

```
Wildcard `nick!user@host` masks, mIRC's level flags, temporary ignores with a duration, and
the `/ignore` that fronts them.

**An ignore hides lines. It never changes state.** That is the invariant the whole prompt
is built on: an ignored person still joins the channel, still appears in the nick list, still
holds their op, and their quit still removes them. `IRCEvent.channelChanged(_:)` carries the
roster and must never be suppressed — suppress the *rendering* of an event, never the event.
A client whose nick list quietly disagrees with the server because of a display filter is a
much worse bug than the one being fixed.

- **One `return`, before everything.** `ConnectionViewModel.append(_:)` now feeds four
  consumers — the line, the activity state, the URL catcher and the chat log — and prompt 12
  left its own de-duplication as a single `continue` ahead of all four for exactly this
  reason. Put the ignore test above that, as an early `return`, so it also covers
  `noteConversation`. Four separate conditions is how the fifth consumer gets missed.
- **Yes, an ignore suppresses the log too**, and this is the note from prompt 12 being
  answered rather than inherited. mIRC logs what it ignores; we do not. A line you were never
  shown, written to disk where you will never think to look for it, is the worst of both —
  and the log is the one consumer whose mistake is permanent. Say so in the Options text.
- **Levels are a pure `OptionSet` in `IRCProtocol`**, beside `IRCMask`, whose own doc comment
  already says it is "for bans and ignores". A letter table is a table, the Linux job builds
  that module, and `CommandParser` and `CaravanUI` both need to speak it. Expiry is not pure
  — it needs a clock — so the entry, the list and the persistence stay in `CaravanUI`.
- **`p c n t i k` are mIRC's and mean what mIRC means.** `m` is in `PLAN.md`'s list without a
  recorded meaning; define it, say in the source that we defined it, and record what would
  make us change it.
- **`k` is the odd one: it does not hide the line, it strips the formatting from it.** So the
  ignore test cannot be a single boolean — one level rewrites the event and the others drop
  it. Keep that visible rather than folding it into the suppression.
- **Never ignore yourself, and never ignore a server.** A mask broad enough to match your own
  `nick!user@host` would silently eat your own echo, and `.server` sources have no nick, no
  user and no host to match on — a `*!*@*` ignore must not take out the MOTD.
- **A bare nick becomes `nick!*@*`**, not the `*!*@host` that `/ban` resolves from the roster.
  A ban wants to survive a `/nick`; an ignore wants to not catch everyone behind one bouncer.
  Opposite defaults for the same-looking input, and both are right.
- **Storage: one key per entry, one line each.** `ignore.<n> = <levels> <mask> [<expiry>]`.
  The `<name>.<field>` shape prompt 11 settled cannot be used here — it parses on the dot, and
  every useful mask has dots in it. This is the answer prompt 13b's keyword and pattern lists
  must reuse rather than inventing a second one.
- **The wire trace is never filtered.** `/debug` and the raw-traffic toggle show what arrived.
  An ignore is a display filter, not a censor of diagnostics, and somebody debugging why they
  cannot see a person must be able to see them.
- The menu item, the `/ignore` with no arguments that lists them, and a list with a Remove
  button in Options' IRC tab — the same shape as Connect's trusted certificates.

Acceptance: with a scripted second client, ignore it by nick and confirm the channel goes
quiet, the tree row does not colour, the URL it posts is not in the catcher and nothing
reaches the log — then confirm the nick list still shows it, and still loses it when it
quits. Ignore with `-u`, watch it lapse. Confirm `/debug` still shows every suppressed line.
Restart and confirm a permanent ignore came back and a lapsed one did not.

Do not:
  - **Highlights, keywords, notifications, sounds.** Prompt 13b, which inherits these
    suppression points rather than adding its own.
  - **Per-network ignores.** mIRC's optional `[network]` argument. Global first, as §15.5's
    convention has it for everything else; the key format above leaves room.
  - **`/ignore on|off`** as a global toggle, and `-x` exceptions. Both are mIRC's, neither has
    been asked for, and an empty list is already "off".
  - **DCC ignores.** `-d` is a flag for a subsystem that arrives in stage 3.
  - **Retroactively hiding what is already on screen or already in the log file.** An ignore
    applies from the moment you set it, exactly as the raw-traffic toggle does.
```

**Status:** complete. All six notes above were consumed and are deleted; what each turned
into is in `BUILD-LOG.md`.

**The note from prompt 12 asked a real question and it is answered "yes": an ignore
suppresses the chat log too.** mIRC logs what it ignores. We do not, on the grounds that a
line you were never shown, written to disk where you will never think to look for it, is the
worst of both — and the log is the one consumer whose mistake is permanent. Said on the
Options surface rather than only here.

**One invariant is worth more than the feature**: an ignore hides lines and never changes
state. `.channelChanged` is not ignorable, so an ignored person still joins, still holds
their prefix, and still leaves the nick list when they quit.

**`m` is ours, not mIRC's.** `PLAN.md` records the flag set as `-pcntikm` without recording
what `m` meant; `IgnoreLevel` defines it as joins, parts, quits and nick changes and says in
its own doc comment that we defined it. `BUILD-LOG.md` carries what would justify changing it.

**The live run cost two harness defects and found one real line.** `run-caravan.sh` hard-coded
a DerivedData hash, so most of the run drove the *previous* prompt's binary — Xcode keys
DerivedData on the project path and every worktree has its own. And a mangled line survived a
failed scripted edit, semantically correct by accident and invisible to both the compiler and
the linter. Both are in `BUILD-LOG.md`.

**Not verified live: the URL catcher staying empty**, which needs the context menu, and the
*typed* `/ignore` — synthetic keystrokes reach the ⌘K switcher and the Options picker but not
the chat input, confirmed twice now. The ignore was seeded through `caravan.conf` instead,
which tests the file format against the person it is for; the command has parser tests and
`applyIgnore` tests through the real path.

---

## Prompt 13b — What deserves your attention

**Item:** Highlights & notifications.

Nick mention, custom keyword and regex lists, per-window and per-event sounds, macOS
notifications, a Dock badge and a menu-bar item — the dedicated notifications interface
§18 deferred, with highlights and private messages as the out-of-the-box triggers.

Split from a combined prompt 13; see 13a for why, and note that 13a runs first so an
ignored line never reaches these rules.

```
Decide what is worth interrupting somebody for, and then interrupt them — once.

**The hazard this prompt is really about is the false positive.** A client that notifies
too much is a client whose notifications get switched off, and then the feature is worse
than absent because the user believes it is working. Every decision below is a filter.

- **`HighlightRules` replaces `BufferActivity.mentions(_:in:)` rather than sitting beside
  it**, per prompt 6's note. Own nick (a toggle, on), a keyword list matched on word
  boundaries, and a regex list. `BufferActivity.caused(by:ownNick:isConversation:)` grows a
  rules parameter and stays pure — it is a table, and it is the reason the four states can
  be tested without a tree to look at.
- **A bad regex costs you the pattern, never the launch.** These come from a text field and
  from a hand-edited file. Compile once on load, report what would not compile where the
  user can see it, and carry on with the rest.
- **Storage is `highlight.<n> = <kind> <pattern>`**, the shape 13a settled, with one
  deliberate difference: split on the *first* space only, because a keyword phrase may
  contain spaces where a mask never can. Say that in the parser rather than leaving the
  next reader to infer it from a `maxSplits`.
- **Three filters stand between a match and a notification, and each is a real bug it
  prevents.** Write them as three named conditions, not one boolean:
  - **Not your own words.** Already handled for activity; a notification has the same rule.
  - **Not something you are looking at.** App frontmost *and* that buffer on screen means
    the line is already in front of you.
  - **Not history.** This is the one that matters and the one that is easy to miss. A
    bouncer reattach replays `CHATHISTORY` through `append(_:)` as ordinary messages — and
    the ones you have not seen before survive prompt 12's de-duplication, correctly, because
    they *are* new to this client. Fifty of them mentioning your nick is fifty notifications
    on connect. The rule: **a line whose `server-time` is more than a few minutes old does
    not alert.** Not a setting; a constant with the reasoning at it.
- **`ChatSettings.logs(_:)`'s per-buffer-kind shape is the wrong fit here, and the note that
  suggested it was written before §18 was reread.** "Highlights and private messages" is not
  three toggles, it is one four-way choice — never / highlights / highlights and private
  messages / every message — and its default *is* §18's sentence. One setting that says the
  thing the design note says beats three that add up to it.
- **Delivery is behind one swappable closure**, and the real one refuses to fire unless it
  is running inside an `.app`. A test bundle must never be able to post a user notification,
  and making that a property of the code rather than of test discipline is what stops it.
- **The Dock badge is derived, never counted.** `AppModel.allBuffers` already knows which
  buffers are at `.highlight`; a second counter incremented and decremented alongside is a
  counter that will drift. Recompute on the two events that can change it — a raise, and a
  selection that clears one.
- **The menu-bar item is off by default.** It is the one surface that occupies space the
  user did not ask for. On, it shows the count and lists the buffers wanting attention,
  and clicking one focuses it.
- **Sounds are system sounds, per event, previewable in the pane.** A picker that cannot be
  auditioned is a picker nobody uses.
- The highlight list UI goes **beside Ignored on the IRC tab**, per 13a's note; the Sounds
  tab is what a trigger *does*.

Acceptance: with a scripted second client, be mentioned by nick in a channel and get one
notification, a sound and a Dock badge; add a keyword and a regex and get the same for each;
watch the badge clear when you look at the buffer. Say your own nick and get nothing. Have
the peer mention you while that buffer is on screen and the app frontmost, and get nothing.
Turn the menu-bar item on, confirm the count and that clicking a row focuses the buffer.
Give the pattern field something that cannot compile and confirm it says so and keeps
working. **Then reattach with a backlog and confirm the replay is silent** — that is the
acceptance that matters, and the one a scripted server can also be made to prove.

Do not:
  - **Per-window sound overrides.** `PLAN.md` says "per-window and per-event"; per-event
    ships and per-window does not, because there is no per-buffer settings store and §15.5's
    global-first convention says invent one only when asked. Record it on the item.
  - **Custom sound files.** System sounds only. A user-chosen `.wav` means a stored path, a
    missing-file story and a security-scoped bookmark, for a preference nobody has voiced.
  - **Notification actions** — reply-from-notification, mute-this-channel buttons. A whole
    interaction model, and §18 defers the dedicated interface anyway.
  - **Speech, flashing the window, or bouncing the Dock icon.** mIRC had all three. Ask
    before adding an interruption that cannot be ignored.
  - **Touching the ignore filter.** It runs above this and must stay there; a line that was
    ignored has already returned before any of this is reached.
```

**Status:** complete. All eight notes above were consumed and are deleted; what each turned
into is in `BUILD-LOG.md`.

**One note was consumed by disagreeing with it.** Prompt 12 suggested copying
`ChatSettings.logs(_:)`'s per-buffer-kind split for the notification triggers. Rereading §18
says otherwise: "highlights and private messages, not every message, not highlights alone" is
one four-way choice, not three toggles that add up to one. `AlertTrigger` is that choice and
its default is that sentence.

**The prompt found a filter neither note mentioned, and it is the important one.** A bouncer
reattach replays `CHATHISTORY` through the ordinary message path, and the lines this client
has not seen survive prompt 12's de-duplication — correctly, because they are new to it.
Fifty of them carrying your nick is fifty notifications on connect. Anything older than
`Alerts.staleAfter` does not interrupt you; the buffer still goes pink, because the backlog
genuinely is unread.

**`BufferActivity.caused` is `@MainActor` now**, which is a real change in kind: the table
used to be a pure function of the event and now reads the user's rules. Every caller was
already on the main actor, and `BufferActivityTests` says why it is annotated.

**Not verified live: the notification banner and the sound.** The permission prompt fired on
launch and was left unanswered — granting a persistent system permission to a debug build is
the user's call, not something to do to their machine mid-acceptance. Nor the Dock badge,
because the Dock is set to auto-hide; `badgeCountsHighlights` drives the real
`NSApplication.shared.dockTile` instead, and the menu-bar count seen live is the same
computation. Everything else held: nick, keyword and pattern each reached `.highlight`, the
menu-bar item read 2, and the broken pattern was listed in red with a warning.

---

## Prompt 14 — Presence

**Items:** Notify list · Away system.

`MONITOR` where available with `ISON` polling as the fallback, online/offline events, a
notify window and sounds. Plus `/away`, auto-away on idle, an optional away nick, and an
away log capturing what arrived while you were gone.

Together because both answer "who is around" — one about other people, one about you —
and both hang off the same presence events.

**Examined for a split alongside prompt 13 and kept together**, on two grounds. The halves
are each a good deal smaller than 13's were: the notify list is `MONITOR` with an `ISON`
fallback and a window, and the away system is a command, an idle timer and a log. And the
shared seam is real if narrower than the sentence above suggests — both read the presence
capabilities `NegotiatedCapabilities` already tracks, and both have to distinguish "absent"
from "this server does not say". Revisit if writing the detail turns up a third feature
hiding inside either half; that is what happened to 13.

**A third feature was hiding, and it is the away log.** "Capturing what arrived while you
were gone" is a capture buffer, a window and a rule about what counts — and most of its job
is now done by things that did not exist when this line was written: the unread rule marks
where you left, the activity states say which windows moved, prompt 12 logs everything and
gives it a viewer, and prompt 13b badges what was addressed to you. What is *not* covered is
the one-glance answer on return. So the away log is reduced to that answer and the window is
deferred, on the item, with the reasoning. This is the split conversation reaching a
different verdict from 13's, which is the point of having it each time.

```
Who is around, and whether you are.

**Both halves have the same trap, and it is the reason they are one prompt: an unknown is
not an absence.** `Member.isAway` is `false` for "here" and for "this server does not offer
`away-notify`"; a notify list with no reply yet is not a list of people who are offline; an
`ISON` that has not come back is not everyone having left. Every state in this prompt is
three-valued — here, gone, not yet known — and collapsing it to two is how a client comes to
announce that all your friends left the moment you connected.

- **`MONITOR` where the server has it, `ISON` polling where it does not.**
  `ServerCapabilities.supportsMonitor` and `.monitorLimit` are already parsed and tested and
  nothing reads them; this is what they were for. Respect the limit and say so out loud when
  the list is longer — silently monitoring the first thirty of forty names is worse than
  refusing, because the ten are indistinguishable from offline.
- **730 and 731 are the events; 734 is an error the user has to see.** 732/733 (`MONLIST`) need
  no case beyond `.raw` — we know what we asked for.
- **The first answer is a summary, not a storm.** Connecting produces one reply naming
  everyone who is online, and turning that into an alert per person is prompt 13b's
  reattach bug wearing a different hat. The first reply after a connection sets the baseline
  and produces **one status line**; only changes after it announce.
- **`ISON` polling is a loop that sleeps to a deadline**, like `IRCSession.idleMonitor()`
  already does, not a repeating timer. Same file, same shape, and the reason is the same:
  a deadline that moves is re-evaluated rather than fired against.
- **Auto-away is off by default.** It speaks on the user's behalf, which is precisely the
  kind of thing to make opt-in; §19's "defaults taken without asking" is about the ones
  nobody would mind. When on, the idle clock is the *system's* — you are away from your
  desk, not from this window — behind a closure so a test is not a test of waiting.
- **Coming back is where the away log went.** One line: what happened while you were gone,
  counted from the activity states and the highlight buffers that already know. A window
  listing the lines would be a second log viewer over data prompt 12 already shows.
- **Away is per connection; the idle clock is one.** You are away on a network, and the
  reason you are away is that you left the room. So the timer lives on `AppModel` and sets
  away on every connected network, and `/away` on one network stays on that one.
- Storage is `notify.<n> = <nick>`, the shape 13a settled. The alert for somebody coming
  online gets **its own toggle** rather than riding on `AlertTrigger`, which describes
  buffer activity and does not describe this — 13b's note asked for that decision to be
  made rather than defaulted.

Acceptance: with a scripted second client, put its nick on the notify list and watch it come
online and go offline, on a server with `MONITOR` and again with the fallback forced. Connect
with two names already online and confirm **one** line rather than two alerts. Set auto-away
to a minute, leave the machine alone, and watch it go away and come back with a summary.
Confirm a server without `MONITOR` still works, and that a list longer than `MONITOR=` says
so.

Do not:
  - **A notify *window*.** The list is five nicks; Options shows them with their state, the
    status window announces changes, and a window for five rows is chrome. Say so on the item.
  - **An away-log window.** See above — reduced to the return summary deliberately.
  - **Per-network away messages or per-network notify lists.** Global first, as everywhere.
  - **`WATCH`.** The third presence protocol, supported by a shrinking set of servers that
    almost all also have `MONITOR`. Two code paths already cost a fallback story.
  - **Presence in the nick list** — dimming away members. It reads off `Member.isAway`, which
    is prompt 3's work and needs only a renderer, but it is a *rendering* change to the
    scrollback's neighbour and belongs with whoever next touches that view.
```

**Status:** complete. All six notes above were consumed and are deleted; what each turned
into is in `BUILD-LOG.md`.

**The split conversation reached a different verdict from prompt 13's.** A third feature was
hiding — the away log — and rather than splitting the prompt it was *reduced*: the unread
rule, the activity states, prompt 12's log viewer and prompt 13b's badges already do most of
what "capturing what arrived while you were gone" meant when the line was written. What none
of them gave was the one-glance answer on return, so that is what shipped. `AwaySummary`.

**Both halves turned out to share one bug, which is the justification for them being one
prompt.** An unknown is not an absence: a notify list with no reply yet is not a list of
people who are offline, and `Member.isAway` is `false` for "here" and for "this server does
not say". `NotifyTracker` is three-valued throughout for that reason.

**One note asked for a decision and got one.** Prompt 13b said an arriving friend is not a
`BufferActivity` and `AlertTrigger` therefore does not describe it — so it has its own
toggle, `alert.notify`, on by default because the list is short and people sign on once.

**The live run found three timing bugs, and a scripted server could not have found any of
them.** The watch list was sent before registration and never retried; then issued at 001,
which is before 005 says whether the server even has `MONITOR`; then closed its baseline on a
five-second deadline that Libera beat by a second, turning the baseline into the exact burst
of false arrivals it exists to prevent. The terminator is now
`NotifyTracker.isComplete` — `MONITOR +` answers every target — with a thirty-second backstop.
All three are in `BUILD-LOG.md`.

**Not verified live: the `ISON` fallback**, since Libera has `MONITOR` and a second server was
not worth a second acceptance; it has an end-to-end test with `MONITOR` absent. Nor the
return-from-away summary, which needs unread buffers and keyboard input in the same breath.
Verified live: the one-line baseline, a change announced on its own, and auto-away taking its
state from the server's 306 rather than from having sent the request.
---

## Prompt 15 — Channel list

**Item:** Channel list window.

`/list` with min and max user filters, name and topic search, sortable columns, and
join-on-double-click. A canvas rather than a buffer, and the first surface that has to
stay responsive while tens of thousands of rows arrive.

**Examined for a split and left whole.** One `PLAN.md` item, one surface, and the thing
that makes it sound large — Libera answers `/list` with about 22,000 channels — is not a
separable second prompt. A list built without that in mind is not a list to make fast
later; it is a list to write again. The performance is a property of doing this once.

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

**Carry-forward** *(consumed when this prompt runs)*

- From prompt 12: **⌘F searches the buffer; the log holds what the buffer has dropped**, and
  the two answers will differ the moment a channel passes `chat.scrollback-lines`. Somebody
  who searched a window and found nothing has not been told the line might be on disk.
  `LogViewerSheet` has a filter field over one file already, so the cheap version is a way
  across — "not in this window; search the log?" — rather than a second search engine.
  Whatever it does, decide it rather than shipping two searches that disagree about what
  "everything" means. A real index over the log directory is not this prompt's and is
  recorded on `PLAN.md` item 20.
- From prompt 12: **`copy without formatting` has a worked example to copy.**
  `LineRenderer.plainLine(kind:fields:at:)` already turns a line into plain text through the
  same `LineFormatTable` the buffer draws with, which is exactly what "copy the sentence
  without the styling" means. The difference is the stamp — the log's is canonical, and a
  copy wants whatever the buffer is showing — so it is a parameter, not a second function.

---

**Stage 2 is done when** you would use this instead of your current client.
