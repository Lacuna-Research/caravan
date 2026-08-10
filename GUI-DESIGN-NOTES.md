# Caravan GUI — design decisions

Working notes from a design conversation. **Not a prompt, not a spec.** These are
settled choices with their reasoning. Folded into the prompt queue and `PLAN.md` by
prompt 7.5 on 2026-08-05 — `STAGE1-PROMPTS.md` and `PLAN.md` are authoritative for
what gets built and when; this file is the reasoning record they cite by section.

Status key: **settled** — decided by the user. **provisional** — recommended and
awaiting confirmation. **open** — genuinely undecided.

---

## 1. Window model — settled
**Single window, sidebar-driven.** Not MDI, not one window per network.

mIRC was MDI: child windows tiled inside a parent frame. macOS has no MDI and
emulating it in 2026 would feel wrong. Detaching a buffer into its own window stays
on the table as an explicit user action, but the primary metaphor is one window.

Consequence: navigation at scale becomes the load-bearing problem, since every buffer
across every network lives in one sidebar. See §9.

## 2. Treebar vs switchbar — settled
**Treebar first. Switchbar to the backlog.**

mIRC shipped both and let you choose. The tree (network → channels/queries/status) is
the macOS-native choice and the one that scales. The switchbar — a flat strip of
buttons — is deferred, not rejected; revisit once the treebar is in real use.

Reference point for tree behaviour is **Chrome's tab management**: grouping,
collapsing, reordering, pinning. Network is the natural group.

## 3. Activity indication — settled
**Keep mIRC's colour-coded states**, add badges only for highlights.

mIRC coloured the tab text across four states — normal / activity / message /
highlight. That carries more information per pixel than a macOS badge count, and
information density is an explicit goal, not an accident of 1995. Badges are additive
for the highlight case only.

## 4. Line layout and the formatting scheme — settled (shape), provisional (mechanism)
**Original mIRC line format: monospaced, left-aligned, one line per message,
wrapping flush-left.** `[12:04:22] <bob> text`. Not a right-aligned nick column, not
proportional text, not sender-grouped bubbles.

Configurable via a formatting scheme rather than hardcoded strings.

**Provisional — two tiers, not one:**

- *Declarative default.* A format table of template strings (`[$timestamp] <$nick>
  $text`) plus a colour per line kind. No JavaScript on the render path.
- *Opt-in JS hook.* For computed formatting, using the same JavaScriptCore layer
  planned for scripting. Documented as slower, never on by default.

Reasoning: a JS call per rendered line cannot hit the 10k lines/sec ingest target.
The two-tier split mirrors the declarative/JS split already planned for scripting
generally, so it is one idea applied twice rather than two mechanisms.

This subsumes the existing plan to "put the colours in one table so stage 2 theming
has a single seam" — make that table hold format strings as well as colours, so there
is one seam rather than two.

## 5. mIRC colour codes across light and dark — settled (shape), provisional (palette)
**An explicit palette toggle, not inference from the system theme.** The user
declares light or dark and the palette shifts accordingly. Per-index user overrides
on top.

Reasoning: mIRC's 16 base colours were chosen against a white background — index 0 is
white, index 1 is black. Rendering them literally on a dark background makes a large
fraction of pasted text unreadable.

**Provisional — a full alternate palette, not a 0↔1 swap.** Swapping just white and
black leaves the other 14 colours still tuned for white; dark blue on black is as
unreadable as white on white. HexChat and Textual both ship a complete second
16-colour palette with luminance adjusted for dark backgrounds. The extended 16–98
range is fixed RGB and mostly survives unchanged.

**Three-state toggle: Auto / Light / Dark.** Auto follows the system appearance;
either of the other two pins it regardless. Offered as a default and unchallenged.

## 6. Nick colourisation — settled
**Hash-based per-nick colours, with manual per-nick override.**

A change from mIRC, which did not colour nicks. Effectively universal in clients
since.

**Hash is seeded on the nick alone**, not nick + network — so `bob` looks like `bob`
whether you reach him directly or through the bouncer. Offered as a default and
unchallenged.

The generated palette must be contrast-checked against *both* backgrounds from §5, so
it cannot be a naive hue wheel.

## 7. Input field — settled
**Single line that grows to roughly six lines as Shift+Enter adds them.**

**A paste never sends. Ever.** Not multi-line pastes, not single-line pastes, not a
paste whose content ends in a newline. Pasted text always lands in the input box for
the user to see before anything leaves the client; Enter is the only thing that sends.

This is a **security rule, not a UX preference.** The failure it prevents is pasting a
password, an API key or a private key into a channel by accident — and that content
is a `PRIVMSG` body, so the `Redactor` cannot help: it only knows the credential-
bearing commands (`PASS`, SASL, `OPER`, NickServ). Pre-send visibility is the only
guard that exists for this case, which makes it load-bearing rather than nice to have.

**Implementation trap:** the dangerous case is a paste with a *trailing newline*, which
copying a whole line from a terminal or editor produces routinely. A naive input
handler treats that newline as Enter and sends immediately. Trailing newlines in
pasted content must be stripped or ignored, never interpreted as a send.

**Supersedes the existing stage-1 command-line plan**, which specifies that pasting
multiple lines sends them as separate messages immediately. Under this rule a
multi-line paste fills the box, and Enter then sends the lines as separate messages.
It also gives stage 3's paste-protection dialog a coherent place to hook in — it
becomes a warning on an already-visible payload rather than the only thing standing
between a paste and the wire. Nothing is built yet, so this is a revision, not a
rewrite.

**Enter sends, Shift+Enter inserts a newline. The box stops growing at six lines and
scrolls beyond that.** Offered as defaults and unchallenged.

## 8. Toolbar — settled
**Menu bar always. Icon toolbar optional.**

**Provisional — use `NSToolbar` rather than a hand-rolled SwiftUI bar.** macOS gives
toolbar customization for free: a drag-and-drop palette sheet, with layout persisted
by the system. mIRC's toolbar editor then becomes mostly not-work-we-do.

**Visible on first launch** with a minimal set — connection state, sidebar toggle,
nick-list toggle. Offered as a default and unchallenged.

## 9. Navigation at scale — settled
The requirement, in the user's words: not having to Ctrl-Tab ten times to reach the
window you want. This is the direct cost of §1 — a single window means one tree holds
every buffer across every network.

Treated as three separate problems with three separate answers, because conflating
them produces something that solves none of them.

**Getting to a window you're thinking of → a fuzzy quick-switcher.** ⌘K-style palette
over every buffer on every network; type a few characters, Enter. The idiom did not
exist in 1995, which is the only reason mIRC lacked it. **Searches buffer names
only** — ⌘F-in-buffer and full-text history search stay separate features with their
own UI.

**Getting to wherever something is happening → next-unread and next-highlight keys.**
Two separate bindings, not one: on a busy network unread is noise and highlights are
not. irssi's single-key "next window with activity" is the model, and it pairs
directly with the four activity states in §3. Likely the highest-frequency navigation
action in daily use.

**Getting back to where you just were → Ctrl-Tab in MRU order.** Explicitly the
Windows Alt-Tab model: tap to toggle between the last two, hold and keep tapping to
walk further back through the list. Chrome's positional Ctrl-Tab is the wrong model
and is widely disliked for exactly this reason.

**Collapsed network groups roll up activity from their hidden children**, showing the
highest-severity state among them. A collapse that hides activity from you defeats
the point. Jumping to a buffer auto-expands and reveals it.

## 10. Debug & Settings canvas — settled
**Debug and settings share one surface, and it is not shaped like a chat window.**
Opened by **⌘0 and by ⌘,** — the latter because forty years of muscle memory makes a
dead ⌘, conspicuous.

This establishes a distinction the app did not previously have: there are **chat
buffers** (channels, queries, per-network status) and there are **canvases**
(Debug & Settings). They are different kinds of surface with different layouts, and
activity states and §11 bindings are concepts belonging to buffers only.

**Placement:** an in-window canvas that replaces the chat area while the tree stays
visible, reachable from a **"Settings & Debug" entry pinned at the bottom of the
tree**. So it appears in the tree without being a buffer — the tree is a navigation
list, not strictly a list of buffers.

**Ejectable to its own standalone window.** Both modes are first-class. Ejection
should be the *same general affordance* used to detach a chat buffer into its own
window (§1), not a mechanism special-cased for this canvas.

Consequences: activating any buffer — by click, by binding, by quick-switcher —
replaces the canvas and returns the chat area. Once ejected, ⌘0 and ⌘, focus the
separate window rather than taking over the chat area.

A departure from mIRC, where the status window is chat-shaped and settings is a modal
tabbed dialog. Also a departure from macOS convention, where Settings is a separate
window only.

## 11. Keyboard binding model — settled
**"Pinned" means remembered, not Chrome-style pinned.** Assigning a shortcut does
**not** reorder the buffer, does not move it to the top of its group, and does not
change its appearance in the tree beyond showing which digit it holds. There is no
pin-to-top concept in the app at present.

The model:

- **Nothing is bound by default.** Bindings are created deliberately by the user.
- **Assignment lives in the tree item's context menu** as `Bind to ▸ 1…9`, with
  already-taken digits shown as such. This is the general pattern for the app, not a
  one-off — there will be many features competing for discoverability, and a
  consistent submenu is the answer rather than a bespoke affordance each time.
- **The tree shows the assigned digit** next to bound items. Unbound-by-default has a
  real discoverability cost and this is what pays it down.
- **A binding attaches to a buffer identity** — network plus buffer name — not to a
  live window object. Otherwise parting a channel or bouncing a connection silently
  drops the binding, and persistent memory is the entire point.
- **Bindings survive restarts**, stored in the plain-text config.
- **⌘0 is reserved** for the Debug & Settings canvas (§10) and is not user-assignable.
  It opens the canvas on demand rather than being inert when it does not exist.

**Provisional — activating a binding whose target is not open opens it.** ⌘3 means
"take me to `#swift`", not "take me to `#swift` if I happen to already be there".
Guard rail: auto-join only if the network is already connected; if it is not, reveal
the buffer in a disconnected state rather than silently dialling out.

**Capacity: nine global slots.** Not nine per network. ⌘3 means the same buffer
everywhere, always — the digit never lies, which is the entire value of binding by
hand. Per-network scoping would trade that away for capacity, and reintroduce exactly
the instability that made mIRC's creation-order numbering useless for muscle memory.
The §9 quick-switcher is the escape hatch for the long tail, and a buffer worth a
permanent digit is by definition one of a small handful.

If nine proves tight in real use, a second modifier tier (⌥⌘1–9) is a purely additive
change later. Deliberately not built now.

User's reasoning, worth preserving: *people may not think about channels, or groups of
channels, in terms of networks at all.* See §12 — this cuts deeper than bindings.

## 12. Tree structure — settled
**Hard rule: every buffer is nested under its network. Always.** No user-defined
groups spanning networks, now or later.

The deciding case: `#music` on Efnet and `#music` on Undernet are different rooms.
Any structure that cannot say at a glance which one you are looking at is broken, and
every grouping scheme that cuts across networks has this problem somewhere. The
briefly-considered cross-network groups idea is closed, not deferred.

Shape:

```
Dashboard                see §13 — new concept, not yet defined
  Efnet                  network row: opens that network's status buffer
    #channel3
    #channel1
    #channel2
    user2  (dm)
    user3  (dm)
  Undernet
    #channel1
    #channel5
    user2  (dm)
    user5  (dm)

        (empty space)

Settings                 pinned to the bottom (§10)
```

**Every row is an ordinary selectable row.** Networks are *not* smaller or
header-styled — they are the same text size as channels, differentiated by decoration
only.

Reasoning: a row styled as a section header but behaving as a selectable item is a
contradiction users have been trained out of, since Finder's "Favourites" and Mail's
mailbox groups are deliberately unclickable. It also avoids faking header appearance
onto a row that must behave normally, which is fiddly in `NSOutlineView`.

**The network row doubles as the status buffer's entry.** Clicking it opens that
network's status window. mIRC carried a separate status node beneath the network;
folding the two together removes a row per network and a concept from the UI.

The network row also carries connection state (disconnected / connecting /
connected) and, when collapsed, the rolled-up activity of its children (§9).

**Queries live in the same list as channels, sorted after them.** Not a separate
labelled section, not intermixed. One flat list per network, channels first, then
DMs — which keeps channel positions stable as transient PMs come and go, without
spending a row of chrome on a section header.

**Above them both, one canvas row: the network's channel list** (stage 2 prompt 15).
The only non-buffer row inside a group, and it is first because it is where the
channels below it come from. It carries no activity dot and no binding digit, those
being concepts belonging to buffers (§10) — but it is a row like any other, and it
ejects into its own window through the same affordance.

**Ordering within a network — provisional: join order, with manual drag-to-reorder,
persisted.** Neither network in the sketch is alphabetical, which rules out sorting as
the only rule.

**Sigils: channels keep `#`, queries take a bullet.** `@` was considered and
rejected — in IRC it already means *channel operator*, and this client renders prefix
characters throughout (§4, nick lists, `<@nick>` in message lines). Teaching two
meanings for one glyph in the same window is not worth the familiarity.

**The tree is set in the system font** — *revised 2026-08-10, and the original is worth
keeping in view.* It read: "the tree is set in a monospaced font; both sigils are one cell
wide, so they form a clean column and names never shift ... a deliberate deviation from
macOS sidebars".

It never happened. `.listStyle(.sidebar)` overrides a `.font` applied to the list for the
rows inside it, so the tree has rendered in the system font since the first build, and the
note went four stages without anybody noticing it described something else. What made it
visible was the one row *outside* the list — pinned "Settings & Debug" — which did obey the
modifier and so sat there in a different typeface from everything above it.

Given the choice between forcing monospace onto rows that have looked native all along and
changing the note to say what the app does, the app won. The column-of-sigils argument was
real but it was buying tidiness in a sidebar, not legibility in a transcript; §4's
scrollback is still monospaced, which is where it earns its keep.

## 13. Dashboard — settled (role), deferred (contents)
**A canvas, not a buffer** — the same kind of surface as Settings & Debug (§10), and
therefore a **peer row above the networks**, not the root of the tree. Dashboard and
Settings bracket the buffer list, which keeps the tree's root level meaningful and
avoids one click collapsing everything.

Contents, as described: connect to a new server; message counts per channel; ping
times per network; a netsplit log; session and all-time statistics. A GitHub-style
activity graph is floated as a possible future addition.

**Dashboard is the splash screen.** It is what you land on with no connections open,
and it holds the server list — pre-populated entries to connect to, plus "Add
server". This also answers the app's empty state, which needed an answer anyway.

**Explicitly long-term.** The statistics, ping times, netsplit log and activity graph
are all "way down the road" and should not be built now. The part that matters early
is the server list and connecting, because it is the app's front door.

**Conflicts with the existing stage-1 plan**, which specifies a Connect *sheet* — a
modal with host, port, TLS, nick, alt nick, ident, real name. If the Dashboard is
where connecting lives, that is a persistent surface rather than a modal, and the two
should not both exist. Nothing is built yet, so this is a revision rather than a
rewrite. (Second such conflict found in this conversation; see also §7.)

**No reserved shortcut.** ⌘0 is Settings & Debug and ⌘1–9 are user-assignable; the
Dashboard is reachable from the tree and does not need a key of its own.

## 14. Header bar — settled
Not a topic bar. **Every buffer type has a header band** across the top of the window,
in the conventional position, monospaced. Only its content and decoration vary:

| Buffer | Header shows |
|---|---|
| Network | the MOTD |
| Channel | the topic |
| Query | conversational context — first and last message, and similar |

**Never hidden, never closable.** Multi-line content may be *shrunk*, but the band
itself is always present. A header that can be dismissed is one people dismiss once
and then forget exists.

Consequence worth planning for: the MOTD is long and multi-line, so the shrink
behaviour is load-bearing for networks rather than an edge case, and the expanded
state needs to scroll rather than grow without bound.

## 15. Fonts and density — settled
Flagged by the user as *objectively one of the most important design decisions* in the
app. In an IRC client the font is a correctness constraint, not a taste preference:
ASCII and ANSI art are part of the culture, and a glyph that renders 1.8 cells wide
destroys art as thoroughly as a missing one. This project has already been bitten
once — `BUILD-LOG.md` records `·` (U+00B7) rendering double-width and breaking the
README's own art.

### 15.1 Default font: **Menlo**, decided on measurement

`Scripts/font-coverage.swift` measures glyph coverage *and* advance width against the
cell, for every system monospaced font. Rerun it before revisiting this. Results at
13pt:

| Font | Box Drawing | Block Elements | Geometric | CP437 art set | Off-grid |
|---|---|---|---|---|---|
| **Menlo** | **100%** | **100%** | **100%** | **44/44** | **none** |
| SF Mono (`monospacedSystemFont`) | 100% | 100% | 14% | 33/44 | none |
| Andale Mono | 31% | 25% | 15% | 44/44 | none |
| PT Mono | 31% | 25% | 15% | 44/44 | none |
| Courier New | 31% | 25% | 16% | 44/44 | none |
| Monaco | 8% | 6% | 2% | 13/44 | 1 |
| Courier | 0% | 0% | 1% | 1/44 | 5 |
| *Helvetica Neue (control)* | *9%* | *3%* | *2%* | *9/44* | *many, up to 1.80×* |

**This reverses the earlier recommendation to use `NSFont.monospacedSystemFont`.** SF
Mono covers box drawing and blocks completely, but is missing eleven of the
forty-four character CP437 art set — `▬ ► ◄ ☺ ☻ ♠ ♣ ♥ ♦ ♪ ♫`, precisely the
high-ASCII staples of BBS- and mIRC-era art. Missing glyphs do not render as blanks;
CoreText substitutes from another font, and the control row shows what substitution
costs — up to 1.80× cell width. SF Mono would break exactly the art it is meant to
show.

Menlo is also marginally narrower than SF Mono (7.827 vs 8.036 at 13pt), which helps
the density goal in §3.

Cost of the choice: Menlo looks slightly less like macOS 2026 than SF Mono. Correctness
wins; SF Mono stays available as a user-selectable option.

**Known limitation:** *no* system monospaced font covers Braille Patterns
(U+2800–28FF) at all — 0% across every candidate. Modern high-resolution braille art
will fall back and break. Accepted; a bundled font is out of scope and would be the
only way to fix it.

### 15.2 Fallback is an explicit cascade, not CoreText's choice

Left alone, CoreText resolves a missing glyph by reaching for whatever font has it,
including proportional ones. That is the 1.80× failure in the control row.

Instead: an explicit fallback chain of **monospaced fonts only** (Menlo → Andale Mono
→ Courier New). Anything still missing renders as a placeholder box rather than
being allowed to break the grid.

### 15.3 Emoji, and why no mode is needed for them

The characters used in ASCII art and the characters used as emoji are *almost*
disjoint. The overlap is exactly `☺ ☻ ♠ ♣ ♥ ♦` — and Unicode already resolves it:
these code points default to **text presentation**, becoming emoji only when followed
by VS16 (U+FE0F).

So: honour the standard. Bare `♥` renders as a one-cell text glyph from Menlo; `♥️`
with VS16 renders as colour emoji at natural width. Art keeps working, and someone
typing an actual emoji gets an actual emoji. Genuine colour emoji are allowed to be
wider than one cell — clipping or squashing them looks worse than the grid break, and
they do not appear in art.

**One toggle, off by default: "Force monospaced grid."** Clamps everything, emoji
included, to one cell. For users whose art still breaks. This is the "two modes" the
user asked about, reduced to one switch, because the three other grid hazards below
need no mode at all — they are simply always on.

### 15.4 The three unconditional rules

- **Ambiguous-width characters are treated as narrow.** The terminal convention, and
  the fix for the `·` bug this project already hit.
- **Line height is clamped.** Combining marks and Zalgo text can blow a single line to
  hundreds of points. This *will* be pasted into a channel.
- **Ligatures are forced off**, even when the user's font has them. A coding font turns
  `!=` into `≠` and `->` into an arrow, mangling quoted code and art alike.

### 15.5 Scope, density and zoom

- **One chat font**, governing scrollback, input box, topic bar and nick list
  together. If the input box does not match the scrollback, what you type does not
  look like what you send. Per-buffer fonts are a later addition, not a v1 feature.
- **Density is line height, not point size** — mIRC's density came from near-zero
  leading, not small text. Expose a line-height multiplier separately from size, with
  zero paragraph spacing between messages by default. Presets (Compact / Normal /
  Comfortable) over raw numbers.
- **Zoom is global**, not per-buffer.

**Project-wide convention, from the user:** *settings are global first; per-window
overrides are added later if wanted.* This is the default approach for the app, not
just for fonts.

**⌘0 collision:** zoom's conventional "actual size" is ⌘0, which §10 gave to
Settings & Debug. Actual-size moves to ⌥⌘0 and the View menu.

### 15.6 Accessibility floor — settled

**The grid survives, and Dynamic Type scales it. Nothing has to give.**

The tension was overstated when this question was first raised. A monospaced grid is a
*relationship between glyph advances*, not an absolute measurement — it holds at any
point size. Scaling the chat font from 11pt to 24pt produces a larger grid, not a
broken one. Dynamic Type and monospace are not actually in conflict.

What *is* in conflict with accessibility is expressing density as fixed point values.
So:

- **Density presets are multipliers, not absolutes.** Compact / Normal / Comfortable
  scale a base size derived from the user's text-size preference, rather than pinning
  it to a number. The user's requested size is never clamped downward.
- **Chrome scales independently.** Sidebar, header bar, dialogs and settings use
  standard system text styles and are not bound to the chat grid — they have no
  alignment to preserve.
- **What is not promised: ASCII art fitting the viewport at large sizes.** Art is a
  fixed-column form meeting a variable-width window, so at large text sizes it wraps.
  This is already true at narrow window widths and is not made worse by accessibility
  settings. Wrapping art beats misaligned art.

The residual risk is not layout, it is VoiceOver over the scrollback — a `NSTextView`
of continuously appended attributed text is where an IRC client actually fails
screen-reader users. That belongs with the stage 4 accessibility work, not here.

## 16. Buffer lifecycle — settled
**Closing a channel buffer parts the channel. Issuing `/part` does not close the
buffer.**

The asymmetry is deliberate, and the invariant it produces is: **membership never
outlives its buffer, but a buffer may outlive membership.** No channel you are joined
to is invisible to you — "no ghosts", in the user's words — while a parted channel
keeps its scrollback and its place in the tree so you can read back and rejoin.

A parted buffer renders in the same not-joined visual state as a buffer whose network
is disconnected (§17), so there is one "you are not in here right now" appearance
rather than two.

## 17. Disconnect behaviour — settled
**A disconnected network keeps its buffers in the tree, greyed.** They do not vanish
and reappear.

Losing your entire tree because wifi dropped is hostile, and it pairs with §11's
bindings attaching to buffer identity rather than live windows — ⌘3 should not break
because a connection did.

## 18. Notifications — settled (default), deferred (interface)
**Default triggers: highlights and private messages.** Not every message, not
highlights alone.

A dedicated notifications interface is planned, so these are the out-of-the-box
defaults rather than the limit of what is configurable. That interface is later work.

## 19. Defaults taken without asking
Recorded so they are visible and easy to overturn, rather than buried as
implementation choices. None of these were felt to warrant the user's time.

- **Nick list** on the right, collapsible, showing a member count, ordered by
  `PREFIX` rank then casemapped alphabetical (already specified in stage 1). Width is
  user-draggable and persisted per app, not per buffer, per §15.5's global-first rule.
- **Timestamps** default to `[HH:mm:ss]`, dim, in a fixed-width column so message text
  forms a clean left edge. Format is user-configurable, strftime-style.
- **Jump-to-latest** appears only when scrolled away from the bottom, and auto-scroll
  resumes only when pinned to the bottom — never yanking the view while reading.
- **Unread marker** is a horizontal rule at the last-read position, persisting until
  the buffer is next left, not cleared the instant it scrolls into view.
- **Scroll-lock** is implicit in the pinned-to-bottom rule above; no separate toggle
  unless one is asked for.
- **First run** lands on the Dashboard (§13), which is the splash and the server list.
  No separate onboarding flow, no wizard.

## 20. Still open
Nothing. Every question raised in this conversation has been answered.

Items deliberately deferred rather than undecided: the switchbar (§2), Dashboard
statistics and activity graph (§13), the notifications interface (§18), per-buffer
fonts (§15.5), and VoiceOver over the scrollback (§15.6).
