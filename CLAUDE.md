# IRC Client — Project Instructions

A native macOS IRC client modeled on mIRC.
`PLAN.md` roadmap · `STAGE1-PROMPTS.md` work queue · `BUILD-LOG.md` history.

## Build standards

- Swift 6 language mode, `StrictConcurrency=complete`, warnings-as-errors on. No
  `@unchecked Sendable` without a justification comment at the conformance.
- Minimum deployment target macOS 15. Tests use swift-testing, not XCTest.
- **Zero external SwiftPM dependencies.** Adding one requires a decision entry in
  `BUILD-LOG.md` and an edit to `Scripts/check-docs.sh`, which fails the build
  otherwise. Vendored test fixtures must record their upstream commit SHA.
- `IRCProtocol` stays pure — no I/O, no Foundation networking, no Darwin APIs. CI
  builds it on Linux, so this fails mechanically the moment it slips.

## Working method

One prompt from `STAGE1-PROMPTS.md` per branch (`prompt-NN-slug`), per PR. Never
commit to `main` directly.

**You merge your own PRs.** Squash-merge and delete the branch once CI is green; a
green PR is authorisation to land it, not a checklist to hand back. Stop and ask only
if CI is red, the work diverged from its prompt, or a decision is genuinely the user's.

**Starting a prompt:** re-read `STAGE1-PROMPTS.md` rather than working from memory of
it, including any `### Carry-forward` block on that prompt.

**Finishing a prompt, before reporting done:**

1. Append a `BUILD-LOG.md` entry — deviations, deferrals, surprises, measurements.
   Not a restatement of the diff; git already has the diff.
2. Raise `### Carry-forward` notes on later prompts for anything learned that changes
   them. Beyond stage 1, attach the note to the `PLAN.md` item instead.
3. Consume notes addressed to this prompt: act on them, delete them, record that.
4. Push anything deferred into `PLAN.md` at the stage where it belongs.
5. Bump the `**Status:**` line in `STAGE1-PROMPTS.md`.
6. `make check` must pass, then merge the PR and `ExitWorktree` with `remove` — a
   prompt ends at the repo root, not in its worktree.

**Between prompts.** Record decisions *at the moment they are made*, never deferred:

- A choice with a rejected alternative → a decision entry in `BUILD-LOG.md`, with the
  reasoning and what would justify revisiting it.
- A change to scope or approach → edit `PLAN.md` / `STAGE1-PROMPTS.md` in the same
  turn. Never answer "good idea, we'll do that" without writing it down.
- A question left open → the **Still open** list in `PLAN.md`, marked blocking or
  not. Unanswered questions are as easy to lose as answers.

## Enforced mechanically

`make check` (pre-commit + CI) enforces: the cap on this file, `BUILD-LOG.md`
append-only, a build-log entry for every `Sources/` change, the status line, the
`README.md` progress badge/table and ASCII art agreeing with their sources,
carry-forward notes not outliving their prompt, and zero SwiftPM dependencies. Two
git hooks and a Stop hook guard the rest: no commits to `main`, no pushing a
`worktree-*` branch before renaming it, no worktree left behind after its PR merged.

When a convention here proves important, make it mechanical rather than writing it
more emphatically.

## Maintaining these documents

Keep docs current without being asked; fix a stale doc in the same commit as the code
that staled it. Reasoning belongs in `BUILD-LOG.md`, not here — this file holds
operative rules, and that split is what keeps it under the cap.

`BUILD-LOG.md` is long and append-only: read its last entries, or search it, rather
than front to back. Open questions are **not** tracked there — they live in one list
in `PLAN.md`, because a question buried in an append-only log is a question nobody
finds.

Revisit it at every stage boundary and **prune as readily as you add** — the 100-line
cap is deliberate and is not to be raised. `PLAN.md` is a living roadmap: reorder,
rescope and delete freely, since `BUILD-LOG.md` preserves the history. Reference
`PLAN.md` items by name, never by number; the numbering shifts.

Propose structural changes here rather than making them silently; prunes need none.

## Where things live

The app writes nothing to its own source tree. No settings, no logs, no captured
traffic, no credentials — not even under a gitignored path.

- Settings, data and caches → `$XDG_{CONFIG,DATA,CACHE}_HOME/irc-client/`, defaulting
  to `~/.config`, `~/.local/share` and `~/.cache` respectively.
- **Credentials → the macOS Keychain, never a file.** Reasoning in `BUILD-LOG.md`.

Config files are plain text and user-editable; treat their paths as public API.

## Secrets

IRC carries live credentials: `PASS`, SASL `AUTHENTICATE`, `OPER`, and NickServ
`identify`/`ghost`/`regain`/`release`/`setpass`. Redaction happens on insert into the
trace buffer, never at export. Never log message payloads through `os.Logger`.

The repo is public. Test fixtures may contain obviously-fake credentials; they must
be recognisable as fake (`hunter2`, `s3cr3t-not-real`) and never a real-shaped token.
