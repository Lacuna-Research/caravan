# Prompt 7.5 — Fold the GUI design decisions into the prompt queue

Sits between prompt 7 (done) and prompt 8 (next). **Docs only — no `Sources/` changes.**

It lives in its own file rather than in `STAGE1-PROMPTS.md` because the task rewrites
`STAGE1-PROMPTS.md`, and instructions that edit the file they are written in are a trap.
Delete this file when the work is merged; `STAGE1-PROMPTS.md` carries the pointer to it.

**Why now and not later:** the notes change the sidebar — activity states, navigation,
tree ordering — and prompt 8 builds the sidebar. Folded in afterwards, prompt 8 gets
redone.

---

```
Fold the settled GUI design decisions into the stage 1 prompt queue.

INPUT
`GUI-DESIGN-NOTES.md`, twenty sections, committed on branch `gui-design-notes` and
pushed. Read it with:

    git show gui-design-notes:GUI-DESIGN-NOTES.md

Read it from the branch, not from a worktree path — the `gui-design` worktree may have
been removed by the time this runs, and an earlier draft of this brief was written
against a stale copy of the file, which is why several of its claims needed correcting.
Check you are reading all twenty sections before starting.

It is explicitly "not a prompt, not a spec": settled choices with reasoning, to be woven
in deliberately. Its status keys matter — **settled** is decided, **provisional** is a
recommendation the user did not challenge, **open** is not decided.

Work on a branch, one PR, never commit to main. Read `CLAUDE.md` first; its conventions
are enforced mechanically and this task trips several of them.

SCOPE
Prompts 1–7 are built and merged — do not rewrite them. The notes land in prompts 8, 9
and 10, in new prompts if the work does not fit those, and in `PLAN.md` for anything
beyond stage 1. Anything the notes change about already-shipped code becomes a
carry-forward on the prompt that will next touch it, or a `PLAN.md` item — not an edit
to a completed prompt.

DO NOT DESTROY THE CARRY-FORWARD NOTES
`STAGE1-PROMPTS.md` currently carries `### Carry-forward` blocks that are unconsumed
input for prompts that have not run yet. Preserve every one of them verbatim unless the
fold genuinely supersedes it, and if it does, say so in the build log rather than
deleting it silently:

  - Prompt 8  — 5 notes (from prompts 5, 6 and 7)
  - Prompt 9  — 2 notes (from prompt 7)
  - Prompt 10 — 3 notes (from prompt 7)

`PLAN.md` has the same on three items: Queries & CTCP, Flood protection, Authentication.

`make check` catches a note that outlives its prompt. It does NOT catch a note deleted
before it was consumed, which is the failure mode here. If you restructure a prompt,
move its carry-forward block with it.

CONFLICTS THAT NEED A RULING
Each of these needs a decision entry in `BUILD-LOG.md` with the reasoning and the
rejected alternative, plus the corresponding edit in the same commit:

  1. §7 input field — and this one is a SECURITY rule, not a UX preference. "A paste
     never sends, ever" contradicts prompt 9's current "pasting multiple lines sends them
     as separate messages" (immediately). The failure it prevents is a password, API key
     or private key pasted into a channel: that content is a PRIVMSG body, so `Redactor`
     cannot help — it only knows the credential-bearing commands. Pre-send visibility is
     the only guard that exists for this case.
     Prompt 9 must be rewritten to match. Two things must survive into the prompt text
     rather than being left to the implementer: pastes with a TRAILING NEWLINE must not
     be treated as Enter (copying a whole line from a terminal or editor produces one
     routinely, and this is the case that slips through review), and stage 3's paste-
     protection dialog becomes a warning on an already-visible payload rather than the
     only thing between a paste and the wire.
  2. §4 formatting scheme. The two-tier format table (declarative templates + opt-in JS)
     subsumes prompt 10's "put the colours in one table so stage 2 theming has a single
     seam". Make it one seam, not two. Note that prompt 7 shipped `LineKind` as that
     table's first form — the fold should say what happens to it.
  3. §10 Debug & Settings canvas. ⌘0, not chat-shaped, and it introduces a
     buffer-vs-canvas distinction the app does not have. This materially changes prompt
     10, which currently owns `/debug` and the status window. Decide whether prompt 10
     absorbs it or a new prompt does.
  4. §3 / §9 / §12 sidebar behaviour — activity colour states, next-unread and
     next-highlight keys, MRU Ctrl-Tab, collapsed groups rolling up activity, tree
     ordering. Prompt 8 builds the sidebar. Decide what is stage 1 and what is stage 2;
     the prompt 8 "Do not" fence needs updating either way.
  5. §11 keyboard bindings and §9 quick-switcher are probably stage 2 — but say so
     explicitly in `PLAN.md` rather than leaving them only in a notes file.

  The six below were missing from an earlier draft of this brief, which was written
  against a stale copy of the notes covering only §3–§12. They need the same treatment
  as 1–5: a decision entry and the corresponding edit in the same commit.

  6. §15 fonts and density — the largest omission, and it touches shipped code.
     `Scripts/font-coverage.swift` on the `gui-design-notes` branch measured every system
     monospaced font and selected **Menlo, not SF Mono**: SF Mono is missing eleven of the
     forty-four CP437 art characters, and CoreText substitutes them from proportional
     fonts at up to 1.80x cell width, breaking exactly the ASCII art it should render.
     Also settled there: an explicit monospaced-only fallback cascade rather than
     CoreText's automatic choice, ligatures forced off, ambiguous-width characters
     treated as narrow, and line height clamped against Zalgo text. This lands in prompt
     10's rendering work, and as a carry-forward on prompt 7's shipped `MessageLogView`.
     Decide whether the font script moves into the repo alongside the decision.

  7. §13 Dashboard replaces the Connect sheet — and prompt 7 already SHIPPED a Connect
     sheet, so this is a retrofit, not a paper conflict. The Dashboard is the splash
     screen, holds the server list, and is a canvas rather than a buffer. Carry-forward
     or `PLAN.md` item; do not edit prompt 7.

  8. §14 header bar generalises what prompt 8 calls a topic bar. Every buffer type gets
     the band: MOTD for networks, topic for channels, conversational context for queries.
     Never hidden, shrinkable. Touches prompt 8 and prompt 10's status window.

  9. §16 buffer lifecycle — closing a channel buffer PARTS the channel, while `/part`
     does NOT close the buffer. The invariant: membership never outlives its buffer, but
     a buffer may outlive membership. Touches prompt 8 (membership) and prompt 9
     (`/part`).

 10. §17 disconnected networks keep their buffers in the tree, greyed, rather than
     vanishing — sharing one "not in here right now" appearance with parted buffers from
     §16. Touches prompt 8.

 11. §19 records six defaults taken without the user being asked, and two land in prompt
     10: `[HH:mm:ss]` timestamps in a fixed-width column, and an unread marker that
     persists until the buffer is next left rather than clearing on scroll. The rest
     (nick list, jump-to-latest, scroll-lock, first run) should be checked against what
     prompts 8 and 10 already say.

THE NOTES HAVE NO OPEN ITEMS — DO NOT REOPEN SETTLED DECISIONS
§20 of the notes states this explicitly: every question raised in that conversation was
answered. `PLAN.md`'s **Still open** list should stay empty unless *this* work raises a
genuinely new question.

An earlier draft of this brief listed six items as open — the palette toggle (§5), the
nick-colour hash seed (§6), input box scroll-vs-grow (§7), toolbar default visibility
(§8), binding capacity (§11) and tree ordering (§12). **All six were settled afterwards**
and every one now carries its answer in the notes. Filing them as open would take
answered questions and un-answer them in the one place the project treats as
authoritative for unanswered ones. Do not do it.

What §20 *does* record is a separate category: **deferred, not undecided** — the
switchbar (§2), Dashboard statistics and the activity graph (§13), the notifications
interface (§18), per-buffer fonts (§15.5) and VoiceOver over the scrollback (§15.6).
Those belong in `PLAN.md` as future items at the stage where they fit, not in the open
list. The distinction is the point: nobody has to decide them, somebody has to build
them.

IF YOU ADD PROMPTS
Adding a prompt means four mechanical edits, or `make check` fails confusingly:
  - `Scripts/check-docs.sh`: `TOTAL_PROMPTS=10` → the new total
  - `STAGE1-PROMPTS.md`: the `**Status:** 7/10 complete.` line
  - `README.md`: the badge, which must contain `stage%201-7%2F<total>`
  - `README.md`: the progress table gains rows, marked `⬜` (the check counts `✅ done`
    rows and compares them to the status line)
Append new prompts at the end rather than inserting — prompts 1–7 are done and the
carry-forward staleness check is numeric, and the notes refer to prompts by number.

ALSO DECIDE
What happens to `GUI-DESIGN-NOTES.md` itself. It is already committed on the
`gui-design-notes` branch, so the question is not whether to save it but whether it lands
on `main` as a standing design document or is distributed into the prompts and left on
its branch as history. Either is defensible — but note that the notes carry *reasoning*
the prompts will not, and `CLAUDE.md` puts reasoning in `BUILD-LOG.md` rather than in the
prompt queue. Whichever way this goes, the reasoning must survive somewhere findable.

Delete `PROMPT-7.5-GUI-DESIGN.md` and its pointer in `STAGE1-PROMPTS.md` as part of this
work — a prompt that has run should not still be sitting in the queue.

DONE WHEN
`make check` passes, `BUILD-LOG.md` has a decision entry covering the fold and each of
the eleven conflicts above, `PLAN.md`'s Still open list is empty or holds only questions
*this* work newly raised, the deferred items have landed as `PLAN.md` entries at the
stage where they belong, every existing carry-forward is either still in place or
explicitly accounted for, and the PR is green.
This is a docs-only change — no `Sources/` edits, so no code review needed, but the
prompts must still read as prompts: self-contained, with a "Do not" scope fence.
```

---

## Reviewing the result

The eleven conflicts are the part worth reading personally — everything else is
transcription, but those are scope decisions. 1 and 3 rewrite prompts substantially, and
6, 7 and 11 touch behaviour that prompt 7 already shipped, so they will surface as
carry-forwards and `PLAN.md` items rather than clean prompt edits.

`make check` verifies document *hygiene*, not whether the prompts still describe the app
you want, so read the diff before merging rather than squash-merging on green.

**Check the fold against all twenty sections of the notes, not against this brief.** This
file has already been wrong once by being written against a stale copy, and a brief is a
summary — the notes are the source.
