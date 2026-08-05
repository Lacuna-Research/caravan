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
`GUI-DESIGN-NOTES.md` — currently uncommitted in the `gui-design` worktree
(`.claude/worktrees/gui-design/`). Read it first. It is explicitly "not a prompt, not a
spec": settled choices with reasoning, to be woven in deliberately. Its status keys
matter — **settled** is decided, **provisional** is a recommendation, **open** is not
decided.

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

  1. §7 input field. A growing multi-line box where a paste *fills the box for review*
     contradicts prompt 9's current "pasting multiple lines sends them as separate
     messages" (immediately). The notes call this a revision; prompt 9 must be rewritten
     to match, or the notes overruled.
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

OPEN ITEMS GO TO THE OPEN LIST
Anything marked **open** in the notes — the two-state vs three-state palette (§5), the
nick-colour hash seed (§6), input box scroll-vs-stop-growing (§7), toolbar default
visibility (§8), binding capacity (§11), tree ordering (§12) — goes into `PLAN.md`'s
**Still open** list, marked blocking or not. Do not quietly resolve them. That list is
currently empty and is the single place open questions live.

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
What happens to `GUI-DESIGN-NOTES.md` itself: committed into the repo as a design
document, or distributed into the prompts and deleted. Either is defensible; leaving it
uncommitted in a worktree is not.

Delete `PROMPT-7.5-GUI-DESIGN.md` and its pointer in `STAGE1-PROMPTS.md` as part of this
work — a prompt that has run should not still be sitting in the queue.

DONE WHEN
`make check` passes, `BUILD-LOG.md` has a decision entry covering the fold and each
conflict above, `PLAN.md`'s Still open list holds every open item, every existing
carry-forward is either still in place or explicitly accounted for, and the PR is green.
This is a docs-only change — no `Sources/` edits, so no code review needed, but the
prompts must still read as prompts: self-contained, with a "Do not" scope fence.
```

---

## Reviewing the result

The five conflicts are the part worth reading personally — everything else is
transcription, but those are scope decisions, and 1 and 3 rewrite prompts substantially.
`make check` verifies document *hygiene*, not whether the prompts still describe the app
you want, so read the diff before merging rather than squash-merging on green.
