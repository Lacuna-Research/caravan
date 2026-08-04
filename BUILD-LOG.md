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

---

## Decision — Toolchain, repo, and workflow

**Date:** 2026-08-04  **Affects:** whole project

**Chose:** full Xcode with a standard app target, over SwiftPM plus a hand-rolled
bundle and `codesign` script. Signing, entitlements and Instruments all come for
free, and prompt 7's scrollback benchmark needs Instruments.

**Chose:** a private GitHub repo, over public. Accepts the cost: macOS Actions
minutes bill at ~10x, so the free tier is roughly 200 macOS minutes a month, and
private repos on the free plan get neither secret scanning nor branch protection.
Both gaps are covered explicitly below rather than left implicit.

**Chose:** one branch and PR per prompt, squash-merged behind green CI, over
committing straight to main. Gives CI somewhere to report before work lands and
keeps a 1:1 history with the prompt list.

**Chose:** zero external SwiftPM dependencies for stage 1. `swift format` ships in
the 6.3.0 toolchain, so SwiftFormat is unnecessary; SwiftLint is dropped entirely
because strict concurrency plus warnings-as-errors covers most of its value.

---

## Decision — Move the meta-system from convention to enforcement

**Date:** 2026-08-04  **Affects:** CLAUDE.md, Scripts/check-docs.sh, CI, STAGE1-PROMPTS.md

A review of the tracking system found seven weaknesses. All seven are addressed
below, and wherever possible the fix is mechanical rather than a more emphatic rule.

**1. Nothing was enforced.** Every rule was a promise audited by the same party who
made it. Now `Scripts/check-docs.sh` runs as a pre-commit hook and as a required CI
job, failing on: CLAUDE.md over its line cap, any edit to existing BUILD-LOG.md lines
(append-only, enforced by diff), a `Sources/` change with no build-log entry, a
missing or malformed status line, carry-forward notes outliving their prompt, and
undeclared SwiftPM dependencies. Warnings-as-errors is on, so zero-warnings is the
compiler's rule rather than ours. The pre-commit hook also refuses commits to main,
which is the only branch protection a free private repo can have.

**2. Prompt 1 had grown into two prompts.** It accreted a four-component Diagnostics
module on top of scaffolding within a single session — the Do-not fences guarded each
prompt's scope but nothing guarded the prompt file itself. Split into `1 — Scaffold`
and `2 — Diagnostics`; everything renumbered, now ten prompts. The references in the
backfill entry above to prompts 1–9 are superseded by this renumbering.

**3. Carry-forward notes had no home beyond stage 1.** PLAN.md items are one-liners
with no note slot, so the convention silently did not apply past prompt 10. PLAN.md
now documents the same `### Carry-forward` block under any numbered item.

**4. No completion state.** STAGE1-PROMPTS.md now carries a machine-readable
`**Status:** N/10 complete. Next: prompt M.` line, which the check script parses and
requires — and which it uses to detect stale carry-forward notes.

**5. No dependency pinning policy.** Vendored fixtures must record their upstream
commit SHA (prompt 3 now requires `Tests/Fixtures/VENDOR.md`), and external SwiftPM
dependencies fail the build unless the check script is explicitly amended.

**6. Tooling was wrong.** `swift format` is in the toolchain at 6.3.0; neither
SwiftFormat nor SwiftLint was installed and neither is needed.

**7. CLAUDE.md was growing before any code existed.** Now hard-capped at 100 lines by
the check script, and rewritten tighter to fit with room to spare. The cap is not to
be raised — it exists to force pruning, which is the thing good intentions never do.

**Also removed:** PLAN.md's stage-1 summary list, which duplicated
STAGE1-PROMPTS.md. Two copies of one list drift, and the copy nobody edits is the one
that gets read. PLAN.md now points at the prompt file instead. STAGE1-NOTES.md, which
prompt 10 was going to create, is likewise gone — BUILD-LOG.md already does that job.

**Cost accepted:** a private repo means no GitHub secret scanning, so CI runs gitleaks
explicitly. This project handles live IRC credentials; that gap could not be left
open.

---

## Decision — Correction: branch protection IS available

**Date:** 2026-08-04  **Affects:** main branch, README.md, .githooks/pre-commit

The entry above asserts that a free private repo gets no branch protection. **That is
wrong.** It was asserted from memory rather than tested. Testing it took one API call
and it succeeded.

`main` is now protected server-side: `discipline` and `secrets` are required status
checks, branches must be up to date before merging, force-pushes and deletions are
blocked, and `enforce_admins` is on — the repo owner is not exempt either. Disable
with `gh api -X DELETE repos/superphly/irc-client/branches/main/protection/enforce_admins`
if it ever gets in the way.

The pre-commit hook's main-branch guard is kept. It is no longer the only line of
defence, but it fails locally in a second rather than after a rejected push.

**Lesson, recorded because it will recur:** a limitation asserted from memory is a
guess. Test the limit before designing a workaround for it — the workaround here
would have been strictly worse than the thing I assumed was unavailable.

---

## Decision — Public repo under Lacuna-Research, and where data lives

**Date:** 2026-08-04  **Affects:** repo settings, CLAUDE.md, PLAN.md, README.md, CI

**Chose:** public, transferred to the `Lacuna-Research` org, over private under a
personal account. Verified before flipping: a full-history scan of every blob ever
committed found no credentials — only the words "password"/"secret" appearing in
documentation about handling them. Branch protection, the required checks, and PR #1
all survived the transfer intact.

Consequences taken up rather than left implicit:
- macOS Actions minutes are now free and unmetered, so prompt 1's Swift CI no longer
  needs to ration runs. That prompt has been updated.
- GitHub secret scanning and push protection are enabled. The gitleaks job stays:
  GitHub's scanner targets provider-issued tokens, while this project's actual risk
  is a captured IRC trace or a real NickServ password pasted into a test fixture.
- Commit metadata is now public, including author name and email address.

**Chose:** XDG-style paths for settings and data, over anything inside the source
tree or an app-specific location invented for the purpose. Settings in
`~/.config/mirage/`, data in `~/.local/share/mirage/`, caches in `~/.cache/mirage/`,
each honouring the matching `XDG_*` variable.

**Chose:** the macOS Keychain for every credential, over a plaintext file under
`~/.config/mirage/`. This is a deliberate narrowing of "settings and secrets both go
in .config". A password in a config file is readable by any process running as that
user and lands unencrypted in Time Machine backups. More decisively: SASL
EXTERNAL/CertFP needs a `SecIdentity` for `NWProtocolTLS`, which is a Keychain item
by construction — so some credentials must live there regardless, and splitting them
across two stores is worse than committing to one.
**Revisit if:** you want config to be fully portable by copying a directory. Say so
and credentials move to a `0600` file under `~/.config/mirage/` instead.

**Consequence caught while editing:** the zero-external-dependency rule rules out
GRDB, which PLAN.md still named for persistence. The persistence layer will wrap the
system SQLite directly. Two documents disagreeing is exactly what the doc-maintenance
rule exists to catch.

### Open

- **Author email in commit metadata is now public.** Not a secret, but a choice.
  Nothing is merged yet and only four commits exist, so switching to a GitHub
  noreply address is still cheap. Say the word.

---

## Decision — Working name is `irc-client`; rename gated to stage 4

**Date:** 2026-08-04  **Affects:** CLAUDE.md, PLAN.md, README.md, STAGE1-PROMPTS.md

**Chose:** `irc-client` as the working name, over `mirage` and over stopping to pick
a final name now. `mirage` was mine, invented as a placeholder while drafting the
prompts; it had no source and nobody was attached to it. It also carries an
unflattering connotation for an app holding credentials, and has prior art in
shipping software.

Applied across the four live documents: target and product `IRCClient`, display name
"IRC Client", bundle id `com.lacuna-research.irc-client`, config at
`~/.config/irc-client/`, data at `~/.local/share/irc-client/`, caches at
`~/.cache/irc-client/`. The `mirage` references remaining in this file are history
and stay; the log is append-only.

**Because:** renaming is find-and-replace right up until the first signed build
leaves the machine, and that is stage 4. Deferring costs nothing now and buys time to
find a name worth keeping. Two things harden at distribution and not before:

- **Bundle id.** Keychain items are ACL'd to the bundle id and code signature.
  Changing it after release strands every stored server password and orphans
  `~/Library/Preferences/<bundle-id>.plist`. Sparkle's feed breaks too.
- **Config paths.** Once a user has `~/.config/irc-client/`, a rename needs a
  detect-and-migrate path that is then carried forever.

**Revisit by:** PLAN.md item 46 (release engineering), which now carries a
carry-forward note stating the gate. The note must be consumed — and the name
settled, or `irc-client` accepted — before anything ships. That is the enforcement:
a note that outlives its item is a process failure, and the carry-forward convention
already says so.

---

## Decision — soju as a first-class target; MQTT rejected

**Date:** 2026-08-04  **Affects:** PLAN.md, STAGE1-PROMPTS.md

**Chose:** treat soju as a primary target rather than a stage-3 afterthought, and
speak IRC to it directly.

**Over:** putting MQTT (Mosquitto) between the bouncer and our clients.

**Because — ordering, decisively.** IRC is a single totally-ordered stream and the
state machine depends on that total order: a NICK must land before subsequent
messages from that user, a QUIT removes someone from several channels atomically,
NAMES arrives in batches that must not interleave. MQTT guarantees ordering within a
topic, not across topics. That forces a dilemma with no good side — fan out to
per-channel topics and lose global ordering, producing rare, subtle, unreproducible
state corruption; or use a single topic to preserve ordering, at which point MQTT is
a worse TCP with a broker in the middle.

Three supporting reasons. It requires writing and hosting an IRC↔MQTT bridge that
re-encodes IRC semantics into topics and payloads — reinventing IRC, worse. The
client could then only talk to that bridge, so it could not connect to Libera
directly, which is a different product from the mIRC-parity goal. And it guts the
diagnostics designed two decisions ago: `TraceBuffer`, `/debug` and the raw `>>`/`<<`
status window all assume raw IRC lines.

Underneath all of it: everything MQTT was being considered for — multi-device
fan-out, offline queueing, push — soju already provides over a protocol we must
speak anyway (`bouncer-networks`, `chathistory`, `@<client>` per-client history,
`webpush`). Verified against soju.im and the project's client support matrix rather
than from memory.

**Also considered and dropped:** MQTT as a one-way event-export sidecar (publishing
highlights to a home automation bus). Legitimate and harmless, since nothing would
depend on it, but it is not wanted now and adding it would be scope invented rather
than requested. Recorded here so it is a known option, not a forgotten one.

**Plan changes made:**
- Multi-network gains two explicit modes — direct (one connection per network) and
  bouncer (`soju.im/bouncer-networks` over one connection) — behind one sidebar model.
- `soju.im/bouncer-networks` and `draft/chathistory` promoted from stage 3 into
  stage 2's IRCv3 capabilities item. Both change how buffers are populated, and the
  logging and multi-window work must not be built before that is settled.
- Logging gains an explicit de-duplication requirement: against a bouncer,
  `chathistory` backfills a period the local log already covers, so buffers must
  merge by message id / `server-time` rather than concatenating both sources.
- Stage 3's bouncer item slimmed to what remains: `filehost`, `metadata`, `search`,
  `webpush`, and ZNC compatibility quirks.
- Local soju added to the testing strategy as the everyday development target;
  prompt 7's acceptance now names it. Stage 1 needs no change to reach it — the
  optional PASS already in prompt 5 is sufficient, with `<user>/<network>` as the
  username.

**Process note:** an item was briefly added as a duplicate `30.` in stage 2 and then
folded into the existing IRCv3 item instead, to avoid renumbering the roadmap.
Related: `STAGE1-PROMPTS.md` referenced "stage 2, items 28–29" by number. PLAN.md is
explicitly a living roadmap whose numbering is expected to shift, so numeric
cross-references between documents are a latent breakage. That reference is now by
name, and future ones should be too.

---

## Decision — CLAUDE.md holds rules, BUILD-LOG holds reasoning

**Date:** 2026-08-04  **Affects:** CLAUDE.md

`CLAUDE.md` had reached 95 of its 100 allowed lines before a line of code existed,
leaving no headroom and guaranteeing that the first prompt needing a rule would hit
the cap mid-flight.

**Chose:** a split that makes the cap sustainable rather than merely painful —
`CLAUDE.md` states operative rules, `BUILD-LOG.md` holds the reasoning behind them.
Where the two overlapped, the reasoning was cut from `CLAUDE.md` and left in the log,
which is where anyone asking "but why" would look anyway. 95 lines to 87.

**Over:** raising the cap, which would have defeated its purpose on the first
occasion it did any work.

Also folded in: reference `PLAN.md` items by name rather than number, promoted from
the previous entry's process note into an actual rule.

---

## Correction — CLAUDE.md line count

**Date:** 2026-08-04  **Affects:** the entry above

That entry says the prune took `CLAUDE.md` from 95 lines to 87. It is 91. The number
was written before the file was measured, which the prompt-entry template in this
file explicitly forbids: "never estimate a number here." Stating a measurement you
have not taken is the same failure as the branch-protection claim earlier — asserting
from expectation rather than checking. Recorded rather than edited, because the log is
append-only, and a small wrong number is exactly the kind of thing that quietly
teaches you the log cannot be trusted.

---

## Decision — I own merges; commit identity is the Lacuna address

**Date:** 2026-08-04  **Affects:** CLAUDE.md, git identity

**Chose:** the assistant squash-merges its own PRs as soon as CI is green, over
handing back a merge checklist for the user to execute. Stated reason: "I don't want
to babysit code." Required status checks plus `enforce_admins` are the gate, so a
green PR is authorisation to land. Escalate only when CI is red, the work diverged
from its prompt, or a decision surfaced that is genuinely the user's.

**Resolves the open question from two entries above.** Commit identity for this repo
is `Cody Marx Bailey <cody@lacunaresearch.com>`, set at repo level so it does not
disturb the global identity used elsewhere. The nine unmerged commits on
`meta-enforcement` were rewritten to that address before merging, since a feature
branch is safe to rewrite and the squash would otherwise have landed the wrong author
permanently.

**Not fixed, deliberately:** the two initial commits already on `main` (185477a,
838491d) keep `superphly@gmail.com`. Correcting them would mean disabling branch
protection, force-pushing `main`, and re-enabling it — destructive ceremony for
cosmetic consistency, on commits that are honestly attributed to the same person.
