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

One prompt from `STAGE1-PROMPTS.md` per branch (`prompt-NN-slug`), per PR,
squash-merged once CI is green. Never commit to `main`.

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
6. `make check` must pass. It also runs as a pre-commit hook and in CI.

**Between prompts.** Decisions made in conversation are the ones most easily lost.
Record them *at the moment they are made*, never deferred to the next wrap-up:

- A choice with a rejected alternative → a decision entry in `BUILD-LOG.md`, with the
  reasoning and what would justify revisiting it.
- A change to scope or approach → edit `PLAN.md` / `STAGE1-PROMPTS.md` in the same
  turn. Never answer "good idea, we'll do that" without writing it down.
- A question left open → the Open section of the latest decision entry, marked
  blocking or not. Unanswered questions are as easy to lose as answers.

Bias toward over-recording. A redundant line costs nothing; a lost decision gets
re-derived, wrongly, weeks later.

## Enforced mechanically

`Scripts/check-docs.sh` runs as a pre-commit hook and in CI. It fails on: `CLAUDE.md`
over 100 lines, any edit to existing `BUILD-LOG.md` lines, a `Sources/` change with no
build-log entry, a missing or malformed status line, carry-forward notes outliving
their prompt, and undeclared SwiftPM dependencies.

Prefer this shape of rule — one a machine checks — over a rule written in a document,
wherever one can be found. When a convention here proves important, the next move is
to make it mechanical, not to write it more emphatically.

## Maintaining these documents

Keep docs current without being asked. Fix a stale doc in the same commit as the code
that staled it; a stale doc is worse than a missing one, because it is trusted.

Revisit this file at every stage boundary and **prune as readily as you add** — the
100-line cap is deliberate and is not to be raised. `PLAN.md` is a living roadmap:
reorder, rescope and delete freely, since `BUILD-LOG.md` preserves the history.

Propose structural changes to this file rather than making them silently; routine
corrections and prunes need no permission.

## Where things live

The app writes nothing to its own source tree. No settings, no logs, no captured
traffic, no credentials — not even under a gitignored path.

- Settings → `$XDG_CONFIG_HOME/mirage/`, defaulting to `~/.config/mirage/`.
- Logs, scrollback DB → `$XDG_DATA_HOME/mirage/`, defaulting to `~/.local/share/mirage/`.
- Caches → `$XDG_CACHE_HOME/mirage/`, defaulting to `~/.cache/mirage/`.
- **Credentials → the macOS Keychain, never a file.** A password in a config file is
  readable by every process running as that user and lands unencrypted in backups.
  CertFP also needs a `SecIdentity` for `NWProtocolTLS`, which is a Keychain item by
  construction — so splitting credentials across Keychain and files would be strictly
  worse than putting all of them in one place.

Config files are plain text and user-editable; treat their paths as public API.

## Secrets

IRC carries live credentials: `PASS`, SASL `AUTHENTICATE`, `OPER`, and NickServ
`identify`/`ghost`/`regain`/`release`/`setpass`. Redaction happens on insert into the
trace buffer, never at export. Never log message payloads through `os.Logger`.

The repo is public. Test fixtures may contain obviously-fake credentials; they must
be recognisable as fake (`hunter2`, `s3cr3t-not-real`) and never a real-shaped token.
