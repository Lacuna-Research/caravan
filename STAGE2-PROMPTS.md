# Stage 2 — The Prompts

**Status:** 6/17 complete. Next: prompt 7.

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

Detachable windows, sharing **one** eject affordance between buffers and canvases (§1,
§10) — this is where the Settings & Debug canvas gains its standalone mode, and where ⌘0
and ⌘, learn to focus that window instead of taking over the chat area. Manual
drag-to-reorder within a network, persisted, on top of join order. `NSToolbar` rather than
a hand-rolled bar (§8).

*To be written out before it starts.*

**Carry-forward** *(consumed when this prompt runs)*

- From prompt 6: **`ConnectionViewModel.buffers` is the one place tree order is written** —
  status, then channels in join order, then queries. Three readers depend on it agreeing with
  itself: `SidebarTree` draws it, `AppModel.allBuffers` flattens it for navigation, and the
  ⌘K palette lists it. Manual drag-to-reorder has to change *that* property, not the tree
  view, or the keyboard and the mouse will disagree about where `#swift` is.
- From prompt 6: **a detached window needs an owner for the selection.** `AppModel.selection`
  is a single optional today, and clearing a buffer's activity, marking its unread rule and
  pushing its MRU entry all hang off its `didSet`. Two windows showing two buffers means
  "the selected buffer" becomes "the selected buffer *per window*", and those three effects
  have to follow focus rather than the one global value.
- From prompt 6: **`CtrlTabMonitor` is installed per view, from `onAppear`.** With a second
  window there would be two monitors racing to handle the same ⌃⇥. Move it to the app, or
  scope it to the key window.

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

**Carry-forward** *(consumed when this prompt runs)*

- From prompt 2: **every command added to `CommandParser`'s switch must also be added to
  `CommandParser.knownCommands`**, directly above it — that list is what Tab completion
  offers, and this prompt roughly triples the table. Swift cannot enumerate a `switch`, so
  nothing will fail if you forget; the command simply never gets offered.
  `everyKnownCommandParses` in `CommandParserTests` catches only the opposite mistake, a
  name listed that the switch no longer handles.
- **Keep `CommandAction` describing *what was asked for*, not what the UI should do about
  it.** This prompt roughly triples the table, so it is where the enum's shape sets. Two
  later things read it as the client's whole vocabulary — stage 3's scripting `irc` object
  and `PLAN.md` item 34a's control socket — and both want "join this channel", not "the
  user typed something in a window". A case that reaches for the selection, a view model or
  a sheet is one those two cannot use, and the divergence is invisible until the second
  front end is built.
- From prompt 5: **`/ctcp` and `/ping` have everything they need already.**
  `IRCProtocol.CTCPMessage` builds the wire form and `IRCEvent.ctcpReply` renders the
  answer, so both commands are one `.send` each. Two things to get right: the request goes
  out as a `PRIVMSG` (a `NOTICE` is a *reply*, and the split is the only thing stopping two
  clients answering each other forever), and `ConnectionViewModel.echo` deliberately draws
  nothing for an outgoing non-`ACTION` CTCP — so `/ctcp bob VERSION` currently shows only
  the answer coming back. Decide there whether asking deserves a line of its own; a
  `.ownCtcpRequest` kind beside `.ownCtcpReply` is the shape if so.
- From prompt 5: **`/query` and `/msg` are now different commands**, not aliases.
  `CommandAction.openQuery(nick:message:)` opens a window with an optional message;
  `/msg` sends and opens the recipient's window as a side effect. `/say` belongs with
  `/msg`. Note that `/query` refuses a channel name via `CommandError.notAPerson`, which is
  the pattern for any later command that wants a person rather than a target.

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
- From prompt 3: **the Connect sheet now collects authentication, and prompt 11 retires that
  sheet** — so the Connect tab inherits it. `ConnectionSettings.AuthenticationChoice` is the
  flat four-option list the picker shows, `Key.authentication`/`.account`/`.certificateLabel`
  are its config keys, and the two passwords go to `CredentialStore` rather than the file.
  The one thing with no UI at all is `KnownHosts`: accepted TLS fingerprints can be forgotten
  only by editing `$XDG_DATA_HOME/caravan/known_hosts` by hand. A list with a Forget button
  belongs on a tab here, and `KnownHosts.forget(_:)` is already written and tested.
- From prompt 2: a Typing section exists too, holding the two nick-completion suffixes
  (`ChatSettings.completionSuffix`, a `CompletionStyle`). Note how they are stored: the
  config format cannot hold a value with a leading or trailing space, so `_` stands for a
  space — `ChatSettings.encodeSuffix`. Any later setting whose value is whitespace-bearing
  has the same problem and should use the same answer rather than inventing a second one.

---

## Prompt 11 — The Dashboard and the server list

**Item:** Server list — the Dashboard.

The Dashboard as a canvas rather than a buffer (§13): a peer row above the networks,
bracketing the tree with Settings & Debug pinned at the bottom. Splash screen and empty
state — first run lands here, no onboarding flow, no wizard. Holds the server list:
groups, per-server nick, password, autojoin channels, perform-on-connect commands,
connect-on-startup, favourites. **Retires `ConnectSheet`**, which is shipped code to
delete rather than a paper plan. Statistics stay deferred to stage 4.

**Carry-forward** *(consumed when this prompt runs)*

- From prompt 6: **⌘1–9 bindings are already persisted, under a key this prompt supersedes.**
  `caravan.conf` holds `binding.3 = irc.libera.chat:6697/#swift` — `host:port`, plus
  `[bouncer-network-id]` where there is one, built by `ConnectionViewModel.bindingNetworkKey`
  and parsed by `BufferBinding.init(rawValue:)`. That was the only durable identifier
  available: `displayName` comes from `ISUPPORT NETWORK=` and the server can change it,
  `id` is a fresh `UUID` per launch. **This prompt answers `PLAN.md`'s "what is a network's
  stable, user-facing name?", so it is also the prompt that migrates these keys** — and
  `caravan.conf`'s keys are public API, so the migration has to read the old form rather than
  silently dropping bindings people made.

*To be written out before it starts.*

**Carry-forward** *(consumed when this prompt runs)*

- **Give every server-list entry a stable, user-editable short name**, and treat it as an
  identifier rather than a label. `PLAN.md` item 34a addresses buffers as `libera/#swift`
  from the command line, and stage 3's scripting will name networks the same way, so this
  is the thing they both hang off. Neither existing candidate serves: `ConnectionViewModel
  .id` is a fresh `UUID` per launch, and `displayName` comes from `ISUPPORT NETWORK=`,
  which the server owns and may change under you. Settle it here — renaming an identifier
  after people have scripted against it is a breaking change with no good migration. It
  wants a uniqueness check and a slug-shaped constraint (no `/`, since that is the
  separator).

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
