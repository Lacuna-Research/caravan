# Build Log

Append-only, chronological, newest at the bottom. Never edit a past entry — if
something here turns out to be wrong, correct it in a later entry and say so.

Two kinds of entry, interleaved in the order they happened:

- **Prompt entries** — what a unit of work produced. Template below.
- **Decision entries** — a choice made in conversation, outside any prompt. Written
  *when the decision is made*, not deferred to the next prompt's wrap-up. A decision
  that waits to be recorded is a decision that gets re-litigated in three weeks.
  Record the alternative rejected and why, not just the choice; the reasoning is the
  part that stops us going around again.

The valuable content in this file is **not** what was built. Git already knows that,
and in more detail. What git cannot tell you is what we did differently from the plan
and why, what we chose not to do, what surprised us, and what we measured. Write
those. If a section has nothing worth saying, write "None" and move on — padding it
makes the file unreadable, and an unreadable log is the same as no log.

---

## Template

```
## Prompt N — <title>

**Commit:** <sha>  **Date:** <YYYY-MM-DD>

**Shipped:** One or two lines. Reference the commit; do not restate the diff.

**Deviations:** Where the implementation differs from the prompt as written, and why.
"None" is a valid and common answer.

**Deferred:** In scope but didn't land, and where it now lives in PLAN.md.

**Learned:** Gotchas, dead ends, surprising API behaviour, things the documentation
got wrong. This is the section that pays for the file existing.

**Measured:** Concrete numbers — benchmark results, timings, line counts. Omit if
nothing was measured; never estimate a number here.

**Carry-forward consumed:** Notes from earlier prompts applied here.

**Carry-forward raised:** Notes appended to later prompts, with prompt numbers.
```

---

## Decision template

```
## Decision — <short title>
**Date:** <YYYY-MM-DD>  **Affects:** <files/prompts/stages>

**Chose:** what we're doing.
**Over:** the alternative(s) rejected.
**Because:** the reasoning. If this decision is ever revisited, this is the line
that gets argued with.
**Revisit if:** the condition that would change the answer. Omit if none.
```

---

<!-- Entries begin below. Newest at the bottom. -->

## Decision — Planning-phase decisions (backfill)

**Date:** 2026-08-04  **Affects:** PLAN.md, STAGE1-PROMPTS.md, CLAUDE.md

Recorded retroactively at the end of the planning conversation, before any code
exists. Everything below was decided in discussion rather than during a prompt.

**Scrollback view: AppKit `NSTextView` (TextKit 2) inside `NSViewRepresentable`**,
over a pure SwiftUI `List`/`ScrollView`. SwiftUI degrades badly past a few thousand
rich-text rows and loses native find, cross-line selection, and link detection.
*Revisit if:* the prompt 6 benchmark shows TextKit 2 underperforming — fall back to
`NSTextView(usingTextLayoutManager: false)` rather than back to SwiftUI.

**Networking: Network.framework (`NWConnection`)** over BSD sockets. TLS,
happy-eyeballs, path monitoring, and client certificates (needed later for SASL
EXTERNAL / CertFP) come free.

**Logging is two facilities, not one:** `os.Logger` for sparse structured
diagnostics with no payloads, and our own in-memory `TraceBuffer` ring for wire
traffic. Over a single unified pipe. The unified log persists to disk outside our
control and is readable by any admin process; `os_log` privacy annotations are
exactly what a "log everything" mode would disable.

**Redaction happens on insert into the trace buffer, never at export.** Over
redacting at export time. If credentials are stripped only on the way out, the
plaintext still exists in the buffer, in crash dumps, and in any future debug path
someone adds. Strip once at the boundary.

**Carry-forward notes live in the destination prompt inside `STAGE1-PROMPTS.md`**,
over a separate notes file. That file is already re-read at the start of every
prompt, so there is no second place to remember to check.

**`BUILD-LOG.md` records deviations, deferrals, surprises and measurements — not
what was built.** Git already holds the diff, in more detail.

**Casemapping lands in prompt 2, not prompt 4.** It is pure logic the
ircdocs parser-tests corpus already exercises; ISUPPORT in prompt 4 then only
selects which mapping is active.

**The event stream is multicast from the start (prompt 5).** A single `AsyncStream`
works until logging and scripting both want the feed, and retrofitting it then
touches every consumer.

**CAP negotiation and SASL are excluded from stage 1 entirely.** Libera accepts
unauthenticated connections, and CAP reshapes the registration state machine enough
that a half-implementation is worse than none. Stage 2, items 28–29.

**Prompts are referenced by number, not pasted into chat.** Keeps
`STAGE1-PROMPTS.md` authoritative; a pasted-and-tweaked prompt makes the file a lie
about what was actually built.

**Platform floor: macOS 15, Swift 6 language mode, strict concurrency complete.**

**Working name: `mirage`** — placeholder, not a decision anyone is attached to.

### Open, blocking prompt 1

- **Full Xcode vs. SwiftPM + hand-rolled bundle and `codesign`.** Only Command Line
  Tools are installed (verified 2026-08-04). Blocks prompt 1's scaffold shape.

### Open, not yet blocking

- **Scripting engine (stage 3):** mIRC-language subset vs. embedded Lua/JSC.
  Leaning mIRC-subset — script compatibility is much of the point of the clone.
- **Distribution:** App Store sandbox vs. direct + notarized. DCC and identd are
  painful-to-impossible sandboxed. Leaning direct.
