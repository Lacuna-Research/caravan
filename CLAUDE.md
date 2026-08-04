# IRC Client — Project Instructions

A native macOS IRC client modeled on mIRC. `PLAN.md` holds the staged roadmap;
`STAGE1-PROMPTS.md` is the current work queue; `BUILD-LOG.md` is the history.

## Build standards

- Swift 6 language mode, `StrictConcurrency=complete`. No `@unchecked Sendable`
  without a written justification in a comment at the conformance.
- Minimum deployment target: macOS 15.
- Tests use swift-testing (`import Testing`), not XCTest.
- Zero compiler and linter warnings before a prompt is considered done.
- `IRCProtocol` stays pure — no I/O, no Foundation networking, no platform APIs.

## Working method

Work proceeds prompt by prompt from `STAGE1-PROMPTS.md`.

**At the start of a prompt:** re-read that file rather than working from memory of
it, including any `### Carry-forward` block appended to the prompt by earlier work.

**At the end of a prompt, before reporting done:**

1. Append a section to `BUILD-LOG.md` using the template at the top of that file.
   Record deviations, deferrals, surprises, and measurements — not a restatement of
   the diff. Git already has the diff.
2. If something learned here changes a later prompt, append a `### Carry-forward`
   note to that prompt in `STAGE1-PROMPTS.md`. Notes live in the destination, not in
   a separate file, so they cannot be missed.
3. Consume any carry-forward notes addressed to this prompt: act on them, delete
   them from the file, and record in `BUILD-LOG.md` that they were applied. A
   carry-forward note that survives its prompt is a bug in the process.
4. Anything deferred out of stage 1 goes into `PLAN.md` at the stage where it
   belongs, so deferral is never silent.
5. One commit per prompt, conventional style, including the doc updates.

`BUILD-LOG.md` is append-only. Never edit a past entry — if something recorded there
turns out to be wrong, correct it in a later entry.

**Between prompts, in conversation:** decisions get made outside any unit of work,
and those are the ones most easily lost. Record them *at the moment they are made*,
not at the next prompt's wrap-up:

- A choice with a rejected alternative → a decision entry in `BUILD-LOG.md`,
  including the reasoning and what would justify revisiting it.
- A change to scope, ordering, or approach → edit `PLAN.md` or `STAGE1-PROMPTS.md`
  immediately, in the same turn the decision is made. Never answer "good idea, we'll
  do that" without also writing it down somewhere durable.
- A question raised and left unanswered → the "Open" section of the latest decision
  entry, flagged as blocking or not. Unanswered questions are a forgetting risk
  equal to unrecorded answers, and they are invisible unless written down.

Bias toward over-recording. The cost of a redundant note is a line of text; the cost
of a lost decision is re-deriving it wrongly weeks later, with no memory that it was
ever settled.

## Maintaining these documents

Keep the repo's documentation current without being asked.

- When code and docs disagree, fix the doc in the same commit as the code. A stale
  doc is worse than a missing one, because it is trusted.
- Revisit this file periodically — at minimum at every stage boundary — and revise
  it. **Prune as readily as you add.** Instruction files rot by accretion: rules get
  appended, never removed, until the file is long enough that nothing in it is read
  carefully. Drop rules the build proved unnecessary, merge duplicates, and correct
  anything experience contradicted. Note what changed and why in the commit message.
- `PLAN.md` is a living roadmap, not a historical record. Reorder, rescope, split,
  and delete freely as reality demands — `BUILD-LOG.md` preserves the history, which
  is precisely what frees the plan to change.
- Keep `README.md` accurate on how to build, test, and run.

Propose structural changes to this file rather than making them silently when they
alter how work is done; routine corrections and prunes need no permission.

## Secrets

IRC carries live credentials: `PASS`, SASL `AUTHENTICATE`, `OPER`, and NickServ
`identify`/`ghost`/`regain`/`release`/`setpass`. Redaction happens on insert into the
trace buffer, never at export. Never log message payloads through `os.Logger`.
