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

---

## Correction — reauthoring the branch did not change the merged author

**Date:** 2026-08-04  **Affects:** the merge-ownership entry above

That entry states the branch commits were rewritten to `cody@lacunaresearch.com`
"since ... the squash would otherwise have landed the wrong author permanently."
The rewrite happened. It did not work.

GitHub's server-side squash-merge sets the resulting commit's author to the **GitHub
account's primary email**, not to the author of the branch commits. `main`'s squashed
commit `6acfd82` is authored `Cody Marx Bailey <superphly@gmail.com>` with committer
`GitHub <noreply@github.com>`, despite every branch commit carrying the Lacuna
address. A new branch was also created and PR #1 closed in favour of #2 purely to
avoid force-pushing — that part was correct, but it bought nothing, because the
attribution was never going to come from the commits.

**What actually controls it:** the email on the GitHub account performing the merge.
Local `git config user.email` governs local commits and is now correct for this repo,
but it is invisible to a squash-merge.

**Requires the user, and only the user:** add `cody@lacunaresearch.com` to the GitHub
account, verify it, and set it as the commit email. Verification needs access to that
mailbox, so it cannot be automated. Until then every squash-merge lands as
`superphly@gmail.com`.

**Alternative if that is unwanted:** merge with `--rebase` instead of `--squash`,
which preserves per-commit authorship — at the cost of putting every commit of a
prompt on `main` rather than one, which conflicts with the one-commit-per-prompt
convention. Not recommended.

**Lesson, and this is the third of its kind:** I asserted that an action would have
an effect without checking how the mechanism actually works — the same shape as the
branch-protection claim and the line count. Two of the three were caught only because
something was verified afterwards. Verify the mechanism, not just the outcome you
expect from it.

---

## Decision — commit identity settled as superphly@gmail.com

**Date:** 2026-08-04  **Affects:** git config; closes the open question above

**Chose:** `Cody Marx Bailey <superphly@gmail.com>` for this repo, over adding and
verifying `cody@lacunaresearch.com` on the GitHub account. Decided by the user once
the constraint was clear: GitHub's squash-merge attributes to the account's primary
email regardless of what the branch commits say, so using the Lacuna address would
have required account-level changes only the user can make.

The repo-level `user.email` override has been removed, so this repository now
inherits the global identity. Local commits and merged commits therefore agree —
which was the actual problem, not the specific address.

`main`'s existing commits are already consistent with this. No history rewrite, no
force-push, nothing further to do. **This closes every question that was open at the
end of the planning phase.** What remains open — the scripting engine, distribution,
and the final name — belongs to stages 3 and 4 and is gated where it is needed.

---

## Prompt 1 — Scaffold (partial)

**Commit:** see PR  **Date:** 2026-08-04

**Shipped:** SwiftPM package `IRCClient` with four library targets and matching test
targets, Swift 6 language mode with warnings-as-errors, `.swift-format`, Makefile
targets, README, and `.github/workflows/ci.yml` with the Linux purity job and the
macOS build/test/lint job.

**Deviations:**
- **Not complete.** Xcode is still not installed — `xcode-select -p` reports
  `/Library/Developer/CommandLineTools`. The `.xcodeproj`, the app target and the
  empty-window acceptance criterion are all outstanding, recorded as a carry-forward
  note on prompt 1. Status stays 0/10; a partially-built prompt is not a built one.
- Cache key is `hashFiles('Package.swift')` rather than `Package.resolved`. With zero
  external dependencies there is no resolved file to hash.
- The purity job builds `IRCProtocol` on Linux but does not run its tests there.
  `swift test --filter` still builds every test target, and Diagnostics will import
  `os.Logger` from prompt 2 and cannot compile on Linux. Carry-forward raised on
  prompt 3.
- Test targets declare `swiftSettings: strict` individually rather than via a
  package-wide default; SwiftPM has no manifest-level default for this.

**Learned:**
- **`swift-testing` and `XCTest` ship with Xcode, not with Command Line Tools.**
  Neither `Testing.swiftmodule` nor `XCTest.swiftmodule` exists anywhere under
  `/Library/Developer/CommandLineTools`. So `make test` cannot run on this machine at
  all, and the tests in this PR were verified by CI rather than locally. This was not
  anticipated when Xcode was treated as needed only for bundling and signing — it
  gates the test loop too.
- SwiftUI, AppKit, Network and OSLog all *compile* fine under CLT; the macOS SDK is
  present. Only testing and app bundling are gated. That is why prompts 2–6, which
  are entirely library work, can proceed with CI as the test oracle.
- `SwiftSetting.treatAllWarnings(as: .error)` requires swift-tools-version 6.2. It
  works, so warnings-as-errors is a package setting rather than a flag callers must
  remember to pass.
- `swift format` rejected the generated test function names
  (`IRCProtocolTargetLinks`) under `AlwaysUseLowerCamelCase`. Acronym-leading names
  need care: the module is `IRCProtocol`, the function is `ircProtocolTargetLinks`.

**Measured:** clean `swift build` of four targets, 12.96s cold.

**Carry-forward consumed:** none — prompt 1 had none.

**Carry-forward raised:** prompt 1 (the outstanding Xcode work, blocking its
completion); prompt 3 (running `IRCProtocolTests` on Linux in the purity job).

---

## Prompt 1 — Scaffold (complete)

**Commit:** see PR  **Date:** 2026-08-04

**Shipped:** `irc-client.xcodeproj` with the `IRCClient` app target, the SwiftUI shell
(`App/`), entitlements, a shared scheme, and an `xcodebuild` step in CI. Completes the
prompt begun in the previous entry.

**Deviations:**
- **`treatAllWarnings(as: .error)` had to come out of `Package.swift`.** It lowers to
  `-warnings-as-errors`, which conflicts with the `-suppress-warnings` Xcode injects
  when compiling package targets as dependencies of an app — every package target
  failed to build with `error: conflicting options`. Setting
  `SWIFT_SUPPRESS_WARNINGS = NO` in the project did not help; Xcode adds the flag for
  package dependencies regardless. Warnings-as-errors now lives at the build
  invocation (`SWIFTFLAGS := -Xswiftc -warnings-as-errors` in the Makefile, and
  explicitly in `ci.yml`), so `swift build`, `swift test` and CI all enforce it and
  the app target enforces it via `SWIFT_TREAT_WARNINGS_AS_ERRORS`. The one gap: package
  targets compiled *through Xcode* no longer treat warnings as errors. CI is the gate,
  so this is acceptable, but it is a genuine weakening worth knowing about.
- **Hardened runtime is set but inert.** `xcodebuild` reports "Disabling hardened
  runtime with ad-hoc codesigning". It requires a real signing identity, which requires
  a paid Apple Developer account. The setting is retained so it takes effect the moment
  a Developer ID is configured; the distribution decision in PLAN.md is where that
  lands.
- The network client entitlement is declared but does nothing while unsandboxed. Kept
  deliberately so enabling the sandbox later cannot silently break networking.
- `.pbxproj` was hand-written rather than generated — no GUI, and XcodeGen would have
  been an external dependency. Uses `PBXFileSystemSynchronizedRootGroup` (objectVersion
  77), so `App/` syncs from the filesystem and new files need no project edit. That
  makes the file about 250 lines instead of the usual sprawl, and means adding sources
  in later prompts touches nothing here.

**Learned:**
- `CGWindowListCopyWindowInfo` reports the window owner as the **display name**
  ("IRC Client"), not the target/executable name ("IRCClient"). My first verification
  reported "NO WINDOW FOUND" and the app was fine — the filter was wrong. Worth
  remembering for prompt 7, where the scrollback benchmark will want window
  introspection.
- Verification of the running app was limited: `osascript`/System Events needs
  assistive access and `screencapture` needs screen-recording permission, neither of
  which this environment has. The window's existence, size, layer and opacity were
  confirmed via `CGWindowList`; its *contents* were not visually confirmed.

**Measured:** app window 900x600 at layer 0, alpha 1.0, matching `.defaultSize`.
Bundle: `com.lacuna-research.irc-client`, display name "IRC Client",
`LSMinimumSystemVersion` 15.0, ad-hoc signed, no embedded frameworks (static). Full
`make all` — build, 4 tests, lint, docs check, xcodebuild — passes.

**Carry-forward consumed:** the prompt 1 note recording the outstanding Xcode work.
Deleted; everything it listed now exists. Status bumped to 1/10.

**Carry-forward raised:** none new. The note on prompt 3 (running `IRCProtocolTests`
on Linux) still stands.

---

## Verification — prompt 1's window contents, visually confirmed

**Date:** 2026-08-04  **Affects:** the prompt 1 completion entry above

That entry recorded an honest gap: the window's existence, size, layer and opacity
were confirmed via `CGWindowList`, but its *contents* were not, because
`screencapture` needed screen-recording permission this process did not have. The
permission has since been granted, so the gap is now closed rather than left standing.

Captured the window directly (`screencapture -l<windowid>`) and inspected it. It shows
what prompt 1 specified and nothing more: title bar reading "IRC Client", a
`NavigationSplitView` with an empty sidebar roughly 228pt wide — consistent with the
`ideal: 220` plus divider — a sidebar-toggle in the toolbar, and an empty detail pane.
`kCGWindowName` also reads "IRC Client", which independently confirms the title
criterion.

**Every part of prompt 1's acceptance criterion is now verified, none of it assumed.**

**Still not available:** `osascript` / System Events accessibility. The failure code
moved from -1728 to -1719 but access is still refused, most likely because the
permission attaches to the process that spawns `osascript` — for a background job that
is not necessarily the terminal application the grant was applied to. Screen capture
is sufficient for this purpose, so this is not worth chasing; noted in case prompt 7's
scrollback benchmark wants UI-element introspection rather than pixels.

---

## Decision — a prompt ends at the repo root, not in its worktree

**Date:** 2026-08-04  **Affects:** CLAUDE.md

Prompt 1 was merged, verified and reported done while the session was still sitting in
`.claude/worktrees/prompt-01-scaffold` on a branch that had already been merged and
deleted. The user noticed via the statusline. Leaving a stale worktree behind is
untidy on its own, but the real cost is that the next prompt starts in a directory
named for the last one, on a dead branch — precisely the confusion that produced the
`prompt-01-scaffold` branch-name collision earlier in this same prompt.

**Chose:** make leaving the worktree step 7 of finishing a prompt, alongside the
build-log entry and the status bump. Over relying on noticing.

**Paid for it under the 100-line cap** by cutting a paragraph that restated what the
numbered list and the following sentence already said, and dropping "bias toward
over-recording" — the rule above it already says record everything, and the reasoning
lives here rather than in the instructions file. 96 lines to 95. This is the cap doing
exactly what it was put there to do: a new rule had to displace an old one rather than
accumulate on top of it.

**Not made mechanical.** `Scripts/check-docs.sh` runs inside the repo and cannot see
the session's working directory, so there is nothing for it to check. This one stays a
written rule, which is weaker than the rest of the enforcement and worth saying plainly
rather than pretending otherwise.

---

## Correction — the worktree rule can be made mechanical after all

**Date:** 2026-08-04  **Affects:** the worktree-rule entry above

That entry concluded: "Not made mechanical. `Scripts/check-docs.sh` runs inside the
repo and cannot see the session's working directory, so there is nothing for it to
check." The premise was right and the conclusion was wrong. `check-docs.sh` cannot do
it — but a **Stop hook** can, because it fires when a turn ends, which is exactly the
moment the rule is about. I reasoned about the one enforcement point already in use
instead of asking what enforcement points exist.

`Scripts/check-worktree.sh` now runs as a Stop hook from `.claude/settings.json` and
blocks the turn with a message telling the agent to leave.

**The hard part was not detection, it was the discriminator.** A naive "am I in a
worktree?" check fires the instant one is entered, which would make it noise, and a
Stop hook that cries wolf gets ignored. Both "just entered" and "finished" are clean
trees, so cleanliness cannot distinguish them. Nor can "commits ahead of main": after
a squash merge the local commits are not ancestors of `main`, so a finished branch
still looks ahead.

The signal that does work is the **upstream branch being gone** — pushed, then its
remote counterpart deleted, which in this workflow happens exactly on squash-merge.
So the hook fires only when: inside `.claude/worktrees/`, working tree clean, an
upstream is configured, and that upstream ref no longer resolves.

**Tested against every state it must tell apart**, in a scratch repo with a real bare
remote: repo root (silent), fresh worktree with no upstream (silent), pushed with a
live upstream (silent), upstream gone but tree dirty (silent), and pushed-merged-
deleted-clean (fires). Five for five. `shellcheck` clean.

**Also:** `.claude/worktrees/` and `.claude/settings.local.json` added to
`.gitignore`. Worktrees are checkouts, not content, and were previously untracked but
un-ignored.

**Caveat:** unlike the other checks, this one is not in CI — it is a local hook, so it
protects this machine and anyone who has the project settings loaded, not the
repository. It also cannot fire if hooks are disabled. Weaker than a required status
check, considerably stronger than a sentence in a document.

---

## Prompt-adjacent — a second discriminator for the worktree hook

**Date:** 2026-08-04  **Affects:** Scripts/check-worktree.sh

Testing the hook against the very worktree that had just been merged exposed a blind
spot the scratch tests missed: it stayed silent. The branch had been pushed with
`git push origin HEAD:name` rather than `-u`, so no upstream was ever configured
locally and signal 1 (upstream gone) had nothing to read. Easy to do by accident, and
precisely the case where the reminder is wanted.

**Added signal 2: content-identical to the base.** After a squash merge the branch's
*tree* matches `origin/main`'s tree while the commits differ. A fresh worktree has
HEAD equal to the base, so it does not match — which is what makes the pair of
conditions (HEAD differs, tree identical) a clean fingerprint for "squash-merged".

**Signal 1 regressed while adding it, and the cause is worth recording.** When the
upstream ref is missing, `git rev-parse --abbrev-ref --symbolic-full-name @{u}` prints
the literal string `@{u}` on stdout and exits 128 — byte-identical to what it prints
when no upstream is configured at all. A guard added to filter the second case
silently swallowed the first. Reading `branch.<name>.remote` and `branch.<name>.merge`
from config and checking `refs/remotes/...` directly is unambiguous; asking rev-parse
was not.

**Seven states now covered**, all passing: repo root, fresh worktree, live upstream,
dirty tree, upstream gone, squash-merged without upstream, and committed-but-unmerged
work. The last matters most for false positives — genuine work in progress must never
be told to pack up.

**Two process lessons from the same episode.** The scratch harness passed five for
five and the thing still had a hole, found only by running it against reality:
synthetic tests check the cases you thought of.

And the first attempt at this fix was pushed as a PR that GitHub reported `DIRTY`
with no checks at all — because after the squash merge of the previous PR, I committed
on top of the *old* branch instead of re-branching from the new `main`, so the two
histories conflicted and GitHub could not compute a merge ref to run `pull_request`
workflows against. The worktree rule being mechanised here would have prevented it:
leaving the worktree forces the next piece of work to start from a fresh checkout of
main. The rule earns its place.

---

## Prompt 2 — Diagnostics

**Commit:** see PR  **Date:** 2026-08-04

**Shipped:** `Log` (four namespaced `os.Logger` categories), `Redactor`, `TraceBuffer`,
`Signposts`. Placeholder files for the module and its test target deleted.

**Deviations:**
- **The Redactor needed a tokenizer, which looks like the IRC parsing the prompt
  forbids.** It is not: it finds a command and its parameter spans and nothing else —
  no validation, no tag unescaping, no message construction — and it must keep working
  on lines `IRCProtocol` would reject, since a trace is worth most when the wire is
  malformed. Kept private to the file. The alternative, redacting a parsed message,
  does not work: inbound redaction happens at framing, before parsing.
- **`AUTHENTICATE` is redacted against an allowlist, not blanket.** `PLAIN`,
  `EXTERNAL`, `SCRAM-SHA-256`, `+` and `*` are mechanism names and control tokens, not
  secrets, and blanking them would hide which mechanism was negotiated — exactly the
  thing you want to see when SASL fails. Everything else in that parameter is a
  credential payload and goes.
- **NickServ subcommands redact *every* argument after the keyword, not just the
  last.** `SETPASS` carries a key as well as a new password, so last-token-only would
  leak. The account name is lost with it, but that is recoverable from context and a
  password is not. Asymmetric cost, asymmetric caution.
- `OPER` keeps the operator name and redacts only the password — the name is useful
  and is not a secret.

**Learned:**
- **Skipping the source prefix is a correctness requirement, not tidiness.** A user
  whose nick is `pass` produces `:pass!pass@host PRIVMSG #dev :hello`, which a scan
  that does not skip the prefix reads as a `PASS` command and redacts. That case is in
  the table.
- `Mutex` from `Synchronization` gives a `Sendable` final class with no actor hop,
  which suits a buffer written from the transport's hot path. An actor would have made
  every `record` call an await from a synchronous framing path.
- `protocol` is a Swift keyword, so `Log.protocol` needs backticks at the declaration.
  The category string is unaffected.

**Measured:** 15 tests across 3 suites, of which 43 are parameterised Redactor cases —
16 credential-bearing, 19 ordinary-traffic, 8 degenerate. Full `make all` (build, test,
lint, docs check, `xcodebuild`) clean.

**Carry-forward consumed:** the note on prompt 2 about credential-shaped test data.
Applied — every fake credential in the tests is `hunter2` or `s3cr3t-not-real`, both
obviously fake and neither shaped like a real token. Note deleted.

**Carry-forward raised:** none. The note on prompt 3 about running `IRCProtocolTests`
on Linux still stands, and this module's arrival is what makes it matter: `Diagnostics`
imports `OSLog` and `Synchronization`, so it cannot build on the Linux purity runner —
which is exactly why that job builds `IRCProtocol` alone rather than running tests.

---

## Prompt 3 — Message parser

**Commit:** see PR  **Date:** 2026-08-04

**Shipped:** `IRCProtocol` — `IRCMessage` (parse and serialize), `IRCTags`,
`IRCSource`, `IRCCommand`, `IRCCaseMapping`, `IRCNick`/`IRCChannelName`, `IRCMask`,
`IRCProtocolLimits` and `String.truncated(to:)`. No `import Foundation` anywhere in
the module — standard library only.

**Corpus:** ircdocs/parser-tests at `6b417e666de20ba677b14e0189213b3706009df6`
(2023-05-29), CC0-1.0. All four files pass: msg-split (35 cases), msg-join (18),
userhost-split (7), mask-match (6). Details and the regeneration command are in
`Tests/IRCProtocolTests/Fixtures/VENDOR.md`.

**Deviations:**
- **Corpus converted from YAML to JSON.** Zero external dependencies means no YAML
  parser; `JSONDecoder` is in the standard library. The corpus uses only plain
  scalars, sequences and maps, so the conversion is lossless, and VENDOR.md carries a
  one-liner that reproduces it from the pinned SHA.
- **Fixtures live in `Tests/IRCProtocolTests/Fixtures/`, not `Tests/Fixtures/`.**
  SwiftPM only bundles resources declared inside a target's own directory, and
  `Bundle.module` is more robust than deriving a path from `#filePath`.
- **`Package.swift` reduces itself to `IRCProtocol` and its tests under `os(Linux)`.**
  This is what consumes the prompt 3 carry-forward: the purity job now runs plain
  `swift test`, which builds *and runs* the parser suite on Linux instead of merely
  compiling the module. Without the reduction it would try to build Diagnostics,
  which imports `os.Logger`, and fail for a reason unrelated to purity.

**Learned:**
- **Swift treats `CR LF` as a single `Character`.** Escaping tag values with
  `for character in value` never matched `case "\r"` or `case "\n"` for a bare CRLF,
  so it passed through unescaped and would have terminated the line early on the wire.
  Both escape and unescape now iterate `unicodeScalars`. The corpus caught this; no
  hand-written test I had written would have. Worth remembering anywhere this codebase
  inspects individual characters of protocol data.
- **The corpus contains two `msg-join` cases with identical atoms and different
  accepted outputs** — `{"asd": ""}` with a space-filled trailing, where one accepts
  `@asd` or `@asd=` and the other only `@asd`. No implementation can pass both by
  choosing per case, so empty tag values serialize to the valueless form, which
  appears in both lists. IRCv3 treats them as equivalent.
- **Eight of my own test expectations were wrong, in the same way.** I had asserted
  byte-identical round-trips, but serialization is *canonical*: `PING :12345`
  correctly becomes `PING 12345`, since a colon is only needed when a parameter is
  empty, contains a space, or begins with `:`. The property worth asserting is that
  serializing and reparsing is a fixed point, plus byte-exact round-trip for lines
  already in canonical form. Both are now tested separately. The raw bytes are not
  lost — `TraceBuffer` keeps the line as it arrived.

**Measured:** 60 tests across 12 suites, of which 66 are corpus cases. Full `make all`
clean, including `xcodebuild`.

**Carry-forward consumed:** the note on prompt 3 about running `IRCProtocolTests` on
Linux. Done via the platform-conditional manifest; the purity job now runs the suite
rather than only compiling. Note deleted.

**Carry-forward raised:** none.

---

## Decision — README as a front door, with its progress claims machine-checked

**Date:** 2026-08-04  **Affects:** README.md, Scripts/check-docs.sh, CLAUDE.md

Rewrote `README.md` as a real project front page: ASCII wordmark, CI and metadata
badges, an ASCII mockup of the planned mIRC-style layout, an ASCII module diagram, a
per-prompt progress table, the full four-stage feature roadmap in collapsible
sections, build instructions, and the data-location table.

**Chose:** marking clearly what exists versus what is planned, over writing the README
in the aspirational present tense. The mockup is labelled "a mockup, not a screenshot"
and a callout says the app currently launches to an empty window. A README that
implies working features the project does not have is the fastest way to lose a
reader's trust, and this one has to survive being read next to a repo that is three
prompts old.

**Chose:** two new checks in `check-docs.sh` rather than trusting the badge to be
updated. A static progress badge and a hand-maintained checklist are exactly the kind
of thing that goes stale, and a stale badge is worse than no badge because it is
confidently wrong. The check derives `stage%201-N%2F10` from the status line and
requires the README to contain it, and separately counts `✅ done` rows in the
progress table and requires that to equal N. Both failure modes were verified by
breaking each one and watching the check fail.

That makes four documents whose agreement is now enforced rather than remembered:
`CLAUDE.md` (length), `BUILD-LOG.md` (append-only), `STAGE1-PROMPTS.md` (status and
carry-forward), and `README.md` (progress).

### Open

- **No licence.** The repository is public with no `LICENSE` file, which means default
  copyright — all rights reserved — regardless of it being publicly readable. The
  README says so plainly rather than implying openness the licence does not grant.
  Picking one is the user's call: MIT and Apache-2.0 are the usual choices for a
  client like this, and the vendored parser-tests corpus is CC0 so it imposes no
  constraint. Not blocking.

---

## Correction — the README ASCII art was misaligned, and is now generated

**Date:** 2026-08-04  **Affects:** README.md, Scripts/render-readme-art.py, check-docs.sh

The user spotted that the art did not line up. Measuring rather than squinting found
two genuine defects and cleared one false alarm:

- **The UI mockup was one column wide on every content row** — 81 against a frame of
  80. Invisible until you look along the right-hand border.
- **Three rows of the architecture diagram had 28-column box interiors against a
  27-column frame**, and the child boxes' `▼` connectors did not sit under the `┬`
  they descended from.
- **The wordmark was fine.** It only lacked trailing spaces, which are invisible.
  Composing it from per-letter blocks reproduced the committed art byte for byte.

**Chose:** generating the art from `Scripts/render-readme-art.py` rather than fixing
it by hand. Hand-drawn box art is exactly the kind of thing that loses a column and
nobody notices for months. The generator pads every cell to an exact width and asserts
it, and paints the architecture diagram onto a character grid at explicit coordinates,
then asserts that each connector shares a column with what it connects to. Alignment
is a postcondition, not a hope. `check-docs.sh` now runs it with `--check`; verified by
hand-editing one character and watching the check fail.

**Also fixed: ambiguous-width glyphs inside frames.** `✉` (U+2709) is
emoji-presented in many fonts and `·` (U+00B7) is East Asian *ambiguous* — both can
render double-width and split a frame for readers whose font disagrees with mine.
Frame interiors are now box-drawing plus ASCII only; `·` survives in captions outside
any frame, where a stray column costs nothing.

**Lesson:** I checked this art by looking at it, which is the one method guaranteed to
miss an off-by-one in a 40-line figure. The same instinct that made every other rule
here mechanical should have applied to the art the first time.

---

## Correction — the wordmark staircased because centred `<pre>` centres each line

**Date:** 2026-08-04  **Affects:** Scripts/render-readme-art.py, README.md

The user reported the top two rows of the banner shifted left by one character. They
were right, and the previous entry's fix caused it.

The generator returned `[r.rstrip() for r in rows]`. That left the six rows at 74, 74,
71, 71, 71, 71 columns — the lower rows are shorter because `T` and `C` have narrower
tails. Trailing whitespace is invisible, so this looked harmless.

It is not, because of *where* the block sits. The wordmark is inside
`<div align="center">`, which GitHub renders as `text-align: center`, and a `<pre>`
**inherits that and centres each line independently**. Six lines of unequal length
therefore centre at six different offsets: the two full-width rows sit about one
character left of the four short ones. Exactly the symptom reported.

**Fixed** by not stripping the wordmark's trailing spaces, so all six rows are 74
columns and centre identically. `rstrip` is still correct for the mockup and the
architecture diagram, which are left-aligned and where trailing spaces are pure noise.

**Twice now on the same figure.** The first pass got the glyph columns right and the
line lengths wrong; this pass fixes the line lengths. The generator's assertions
covered *internal* alignment — glyph blocks equal height, cells padded to width,
connectors sharing a column — and said nothing about how the block would be laid out
by the thing rendering it. Correct-in-isolation is not the same as correct-in-context,
and only one of those is what the reader sees.

The generator's `--check` failure message now names stripped trailing whitespace as
the likely cause, since that is what an editor or linter would silently do to it.

---

## Decision — handoff hardening before a context reset

**Date:** 2026-08-04  **Affects:** PLAN.md, CLAUDE.md, .githooks/pre-push, README.md

Audited what was true only in the working session rather than on disk, ahead of
clearing context. Three gaps, all now closed.

**1. Open questions were scattered.** They sat in four separate `### Open` sections
across a 950-line append-only log plus one list in `PLAN.md`. A cold session would
have had to trawl `BUILD-LOG.md` front to back to find them, which is exactly what
nobody does. `PLAN.md`'s **Still open** list is now the single home for open
questions, and `CLAUDE.md` says so and says not to read the log front to back. The
licence and the final-name questions have been lifted out of the log into it.

**2. The branch-rename mistake had no guard.** `EnterWorktree` creates
`worktree-<name>`; forgetting to rename before pushing produced `src refspec does not
match any`, and working around it with `git push origin HEAD:<name>` left the branch
with no upstream — which then blinded the stale-worktree Stop hook, because that is
one of the two signals it reads. I made both mistakes, the second one twice.
`.githooks/pre-push` now refuses to push a `worktree-*` branch and says how to fix it.
Verified firing and passing either side of a rename.

**3. `CLAUDE.md` had one line of headroom.** Now 98, after compressing three
paragraphs that restated things said elsewhere. Worth noting that adding the two
orientation lines a cold session needs pushed the file over the cap and forced this —
the cap working as designed rather than as an obstacle.

### State at handoff

`main` at 3/10 prompts, clean, no open PRs, no worktrees, all eight checks green.
`IRCProtocol` and `Diagnostics` are implemented and tested; `IRCTransport` and
`IRCSession` are still stub placeholders. Next is prompt 4, transport, which has no
carry-forward notes waiting.

### Things learned that are worth not relearning

- **`swift-testing` and `XCTest` ship with Xcode, not Command Line Tools.** Without
  full Xcode there is no test loop at all.
- **Swift treats `CR LF` as one `Character`.** Anything inspecting protocol data
  character by character should iterate `unicodeScalars` instead.
- **A centred `<pre>` centres each line independently.** Ragged line lengths inside
  `<div align="center">` visibly staircase, which is why the wordmark keeps its
  trailing spaces.
- **`treatAllWarnings(as: .error)` in `Package.swift` breaks Xcode app builds**, since
  Xcode injects `-suppress-warnings` for package dependencies. It lives at the build
  invocation instead.
- **After a squash merge, re-branch from `main`.** Committing onto the old branch
  produces a conflicted PR that runs *no* checks at all, because GitHub cannot compute
  a merge ref.
- **My own recurring failure mode:** asserting how a mechanism behaves instead of
  testing it — branch protection availability, the merged-commit author, a line count,
  the ASCII art. Every one was caught by checking afterwards, and every one would have
  been cheaper to check first.

---

## Decision — scripting is JavaScript via JavaScriptCore, not the mIRC language

**Date:** 2026-08-04  **Affects:** PLAN.md, README.md; closes the stage-3 scripting question

**Chose:** JavaScript hosted in `JavaScriptCore`, with a small declarative layer above
it for aliases and popups.

**Over:** reimplementing a subset of the mIRC scripting language, which the previous
entries had been leaning toward. The user's call, and the right one. mIRC-script is an
idiosyncratic language — `$identifiers`, `%variables`, `/commands` as control flow —
that nobody knows outside mIRC, and writing an interpreter for it is a large,
open-ended subsystem to build and then maintain forever. "In the spirit of mIRC" does
not oblige us to inherit its syntax.

**What that forfeits, stated plainly:** compatibility with the existing corpus of mIRC
scripts, which was the whole argument for the subset. The stage-4 mIRC importer can
still bring across settings, server lists and aliases; `remote.ini` scripts will not
run. That is a real loss and it is being accepted deliberately.

**Over Lua**, which was the strongest technical alternative — designed for embedding,
tiny, natural sandboxing, and precedent in WeeChat and HexChat. Rejected because it
means vendoring C source into the package, and the zero-external-dependency rule is
the constraint this project has bent least. JavaScriptCore ships with macOS, so it
costs nothing and does not require amending `Scripts/check-docs.sh` — a system
framework is not a SwiftPM dependency.

**Over Python** (excluded by the user; also nothing embeddable ships with macOS) and
over compiled Swift plugins (a build step is the wrong ergonomics for someone writing
three lines to auto-op a friend).

**Verified before choosing, rather than assumed:**
- A bare `JSContext` exposes **no ambient authority**: `require`, `process`, `fetch`,
  `XMLHttpRequest`, `WebSocket`, `localStorage` and `open` are all `undefined`. Only
  pure-compute globals exist — `Function`, `eval`, `JSON`, `Math`, `Date`. The sandbox
  is the *default state*, and capabilities are injected deliberately. That is a
  structurally stronger position than restricting a language that starts with ambient
  authority, which is exactly how mIRC scripts became a malware vector.
- Swift closures inject cleanly and are callable from script; exceptions surface
  through `exceptionHandler` rather than vanishing.
- `JSContext.isInspectable` is **public** API from macOS 13.3: Safari Web Inspector
  attaches to a live context, giving breakpoints and a console. Better debugging than
  mIRC ever offered.

**Two layers, mirroring mIRC's own aliases / popups / remote split** — the spirit
rather than the syntax. Aliases and popups stay declarative one-liners in a text file,
because "three lines to auto-op a friend" is most of why mIRC scripting caught on and
making people write JavaScript for that would be a regression. JavaScript handles
anything with logic in it.

### Open

- **Runaway-script preemption is unsolved.**
  `JSContextGroupSetExecutionTimeLimit` is present in the framework binary — confirmed
  by `dlsym` — but is not exposed in the public headers; it lives in
  `JSContextRefPrivate.h`. Either declare the prototype and accept an unsupported
  dependency on private API, or run scripts in an XPC helper that can simply be
  killed, which is heavier but also buys a real OS sandbox. Decide while building
  stage 3, with the DCC and identd sandboxing questions in view, since they push the
  same way. Recorded here rather than in `PLAN.md`'s open list because it is a
  sub-question of an item that is otherwise settled.

---

## Decision — the app is Caravan, licensed BSD 3-Clause

**Date:** 2026-08-04  **Affects:** everything; closes two open questions and the stage-4 naming gate

**Name: Caravan**, after *Planet Caravan*, Black Sabbath, 1970. The user's choice.
Explicitly **not** a theme: the app is not to be styled after the band, now or later.
The user reserves the right to hide an easter egg or two, which is recorded here so a
future session neither builds a Sabbath skin nor deletes a deliberate easter egg as
stray cruft.

Applied everywhere, which is the whole point of having gated it: display name
`Caravan`, target and product `Caravan`, `Caravan.xcodeproj`, bundle id
`com.lacuna-research.caravan`, SwiftPM package `Caravan`, config at
`~/.config/caravan/` with data and cache to match, and the GitHub repository renamed
to `Lacuna-Research/caravan` (old URLs redirect). Module names — `IRCProtocol`,
`IRCTransport`, `IRCSession`, `Diagnostics` — are descriptive rather than branded and
deliberately unchanged.

**This consumes the naming gate** carried on the stage-4 release-engineering item
since the rename was first flagged. It was the right call to gate it: the bundle id is
frozen by Keychain ACLs at first signed build, and the config paths would have needed
a detect-and-migrate path carried forever. Doing it now cost a mechanical rename and a
regenerated wordmark; doing it after shipping would have cost a migration.

Verified after renaming rather than assumed: `make build`, `make test` (60 tests),
`make lint` and `make app` all clean, and the built bundle reports
`CFBundleDisplayName` = `Caravan` and `CFBundleIdentifier` = `com.lacuna-research.caravan`.

**Licence: BSD 3-Clause**, copyright 2026 Lacuna Research. The user said "BSD"; the
3-clause variant is the reading taken because it is what unqualified "BSD" most often
means and because its non-endorsement clause protects the organisation's name on a
product that carries it. Switching to 2-clause is a one-file change if that reading is
wrong. The vendored parser-tests corpus is CC0-1.0 and imposes nothing.

That closes the only open item that actively misrepresented the project: a public repo
with no `LICENSE` is all-rights-reserved regardless of being readable.

**Open questions remaining: one** — distribution, App Store sandbox versus direct and
notarized. Everything else that was open is now decided and written down.

**Incidental:** the wordmark generator needed `A` and `V` glyphs it had never had, and
the bulk rename missed `IRC-CLIENT` — a third spelling alongside `IRCClient` and
`irc-client` — because it only appeared as the generator's default argument. Caught by
regenerating and looking at the output, which is the check that exists precisely
because looking at it is unreliable.

---

## Correction — the SwiftPM build cache is not relocatable

**Date:** 2026-08-04  **Affects:** .github/workflows/ci.yml

The macOS job failed on the rename PR with `missing required module 'SwiftShims'` and,
more usefully, `precompiled file ... was compiled with module cache path
/Users/runner/work/irc-client/irc-client/... but the path is currently
/Users/runner/work/caravan/caravan/...`.

Nothing to do with the rename being wrong. SwiftPM's `.build` directory stores
**absolute paths** in its module cache, so a cache restored into a different checkout
path is unusable. The cache key was `${{ runner.os }}-spm-${{ hashFiles('Package.swift') }}`,
which captures the manifest but not the path — so the runner happily restored a cache
built under the old repository name into the new one.

Fixed by putting the repository name in the key. A rename changes the path and the
name together, so the key now invalidates exactly when the cache becomes invalid.

**Latent, not new.** This would have fired on any change to the checkout path and been
far more confusing without a rename to point at. Renaming the repo was the one action
guaranteed to surface it, which is a small argument for doing disruptive things early
while the diff is still readable.

---

## Decision — distribution is a Homebrew cask in our own tap

**Date:** 2026-08-04  **Affects:** PLAN.md, README.md; closes the last open question

**Chose:** a Homebrew cask published from `Lacuna-Research/homebrew-tap`.

**Over the App Store**, which was the alternative half of this question and which the
architecture had already been quietly betting against: DCC needs to accept incoming
connections and write files the user chooses, and identd wants port 113. Both are
painful to impossible sandboxed. The app target has been configured un-sandboxed since
prompt 1 on that assumption; this makes the assumption a decision.

**Over homebrew-cask core**, at least initially. Core has notability requirements a
brand-new project will not meet, and a tap is one Ruby file we control outright.
Submitting upstream later costs nothing that this forecloses.

### What follows from it

- **Developer ID signing and notarization are required, and that costs money.** A cask
  installs into `/Applications`, so Gatekeeper quarantines it; an unsigned or
  un-notarized app greets the user with "damaged and can't be opened". That means a
  paid Apple Developer account, and it is the real price of this choice rather than a
  detail. Worth knowing now rather than at release.
- **The hardened runtime setting was right after all.** It has been set since prompt 1
  and reported inert under ad-hoc signing. Notarization *requires* it, so it becomes
  live the moment a Developer ID exists — no change needed.
- **Sparkle is dropped.** `brew upgrade` is the update mechanism. Shipping a second
  updater that rewrites an app Homebrew believes it manages produces exactly the drift
  Homebrew exists to prevent. Reconsider only if direct download becomes a second
  channel. This removes a planned dependency, which is the direction this project
  prefers to move.
- **The XDG decision pays off here.** A cask's `zap` stanza can remove
  `~/.config/caravan`, `~/.local/share/caravan` and `~/.cache/caravan` in three lines.
  Had settings been scattered across `~/Library` the way a typical Mac app does it,
  clean uninstall would have been a scavenger hunt. That was chosen for tidiness and
  turns out to have been chosen for uninstall too.

**Nothing is built yet** — no tap repository, no release workflow. This is stage 4 and
recording the decision is the whole of the work today.

### Open

*None.* Every question raised during planning and the first three prompts is now
decided and written down. New ones go in `PLAN.md`'s **Still open** list.

---

## Prompt 4 — Transport

**Commit:** see PR  **Date:** 2026-08-05

**Shipped:** `IRCTransport` — `LineFramer`, `WireDecoding`, `TransportState` /
`TransportError` / `TLSMode` / `TLSCertificate`, and the `IRCConnection` actor over
`NWConnection`. 93 tests across 16 suites, `make all` clean including `xcodebuild`.

**Deviations:**
- **`TransportState.failed` carries a concrete `TransportError`, not `any Error`.** The
  prompt says `.failed(Error)`, but `any Error` is not `Sendable`, so the state stream
  would not be either. `any Error & Sendable` would work and would leak `NWError` — and
  with it `import Network` — into every consumer. A closed enum keeps the state stream
  `Sendable` *and* `Equatable`, which is why the state assertions in the tests are one
  line each. `NWError`'s detail survives as the reason string, which is all a
  diagnostic needs.
- **No "connection refused" test.** There is nothing to assert: see below.

**Decisions:**
- **One `IRCConnection` is one connection attempt.** `connect` may be called once, and
  both streams finish at the terminal state. Reconnect means a new instance. The
  alternative — a reusable connection — needs the streams to survive across attempts,
  which `AsyncStream` does not do, and it lets a retry inherit half-torn-down state.
  Revisit only if per-attempt allocation ever shows up in a profile, which it will not.
- **No outbound queue of our own.** `send` is actor-isolated, so call order is enqueue
  order, and `NWConnection` writes each `send` contiguously and in order on a stream
  connection. A second queue would only be a second thing to get wrong. The
  fifty-messages-in-order test exists to catch this being untrue.
- **An overlong outbound message is truncated, not dropped.** The server truncates it
  anyway; doing it here keeps the trace agreeing with the wire. Tags are left alone —
  their 8191-byte budget is separate and nothing stage 1 sends comes near it.
- **The framer emits empty lines rather than swallowing them.** A stray `CRLF` becomes
  an empty line, gets traced, and is dropped by `IRCConnection` because it parses to no
  command. Keeping the policy out of the framer means the framer has no policy at all.
- **Decoding falls back UTF-8 → Windows-1252 → Latin-1.** cp1252 before Latin-1 because
  it maps the 0x80–0x9F range to smart quotes and dashes rather than C1 controls, which
  is what an old Windows client actually sent. Latin-1 last because all 256 byte values
  decode under it, so the function cannot fail and cannot half-replace a string.
- **The TLS verify block is installed only on the `allowSelfSigned` path.** The ordinary
  path keeps stock system validation rather than our reimplementation of it — the
  smallest possible surface for getting certificate checking wrong.

**Learned:**
- **A refused connection never becomes `.failed`.** `NWConnection` sits in
  `.waiting(ECONNREFUSED)` and retries indefinitely; there is no timeout unless someone
  imposes one. The transport reports `.waiting` as non-terminal and stays in
  `.connecting`, which is correct for this layer and useless on its own. Carried to
  prompt 5, which owns the connect deadline. Worth knowing before writing a "connection
  failed" test that would simply hang.
- **The framer counted a terminating `CR` against the line limit**, so a line of exactly
  the maximum length was dropped as overlong. A trailing `CR` is now excluded from the
  count until the next byte proves it was data. Caught by the test that used the exact
  limit rather than a number near it — the off-by-one only exists at the boundary, so
  only a test at the boundary finds it.
- **`Mutex` is non-copyable**, so the TLS verify block could not capture one out of the
  actor (`'self.certificateBox' is borrowed and cannot be consumed`). It needed a small
  reference-type box holding the `Mutex`. Anywhere a `Synchronization.Mutex` has to
  reach an escaping closure, this will come up again.
- **`NWEndpoint.Port(rawValue: 0)` succeeds.** Port 0 means "any port", which is
  meaningful for a listener and meaningless for a client, so the guard that was supposed
  to reject it did nothing. Rejected explicitly now.
- **Actor `let` properties are isolated unless marked `nonisolated`.** `inbound` and
  `state` are immutable and `Sendable`, and still needed the annotation before a
  consumer could iterate them without `await`.

**Measured:** 93 tests, 0.03s for the whole suite; the eleven loopback integration tests
run in ~22ms and were repeated ten times consecutively without a flake.

**TLS verification, and its deferral.** Standing up a TLS listener in-process needs a
`SecIdentity`, which needs a keychain item or a hand-rolled self-signed certificate —
a lot of machinery to end up testing Apple's TLS stack rather than our use of it. The
alternative coverage was none, so instead there is a network-gated suite
(`CARAVAN_LIVE_TESTS=1 swift test --filter LiveNetworkTests`) that connects to
`irc.libera.chat:6697`. Run by hand on this branch: both cases pass in ~2.6s, the
handshake completes, Libera's greeting notices arrive parsed, and the verify block
records the certificate as system-trusted. CI never runs it and an ordinary
`swift test` never touches the network.

**Carry-forward consumed:** none — no note was addressed to prompt 4.

**Carry-forward raised:** four on prompt 5 (connect deadline, one-attempt-per-instance,
`.failed` versus `.cancelled` for reconnect, and the loopback server as the basis for
the scriptable fake). One on `PLAN.md`'s Authentication item: self-signed acceptance
needs a trust-on-first-use prompt, and the transport already surfaces the subject and
SHA-256 fingerprint such a prompt would show.

---

## Prompt 5 — Registration and connection state machine

**Commit:** see PR  **Date:** 2026-08-05

**Shipped:** `IRCSession` — `ServerCapabilities` (ISUPPORT), `ServerInfo`,
`SessionState`/`DisconnectReason`, `SessionConfiguration`, `BackoffPolicy`, and the
`IRCSession` actor: registration, nick fallback, PING/PONG, ERROR, idle detection,
connect deadline and reconnect. 130 tests across 19 suites; `make all` clean.

**Deviations:**
- **A shared test-support target, `Tests/Support`.** Prompt 4's carry-forward preferred
  this over copying the loopback server, and the scripted server needed the same bones.
  It is a plain target, not a test target, because SwiftPM has no way for one test
  target to depend on another; it is in no product, so it cannot reach a consumer.
  `LocalTCPServer` was replaced outright by `ScriptedIRCServer` rather than left
  alongside it, and the transport suite now drives the new one.
- **432 is handled, though the prompt only names 433.** An erroneous nickname cannot be
  fixed by appending an underscore — the server is rejecting the shape of the name, not
  its availability — so retrying asks the same question again. It fails immediately
  with a clear reason instead of grinding through candidates until the deadline.
- **A failure emits `.disconnected(reason:)` *and then* `.reconnecting`.** Two
  transitions where the prompt's state list implies one. `.reconnecting` carries an
  attempt and a delay but no reason, so without the pair a consumer could watch the
  client reconnect and never learn what went wrong.

**Decisions:**
- **`ISUPPORT` is stored raw and derived on write.** `rawTokens` keeps every token,
  including ones with no typed accessor, so the status window can show what the server
  actually said; the typed properties are recomputed on each change. Negation is then
  just a removal followed by a refresh back to the protocol default. Derived on write
  rather than read because `caseMapping` is consulted on every nick comparison in the
  app, and reparsing a string there would be absurd.
- **`ERROR` schedules a reconnect.** Most are transient — "Closing link: ping timeout" —
  and a client that goes quiet after one is worse than one that retries. Rejected:
  treating `ERROR` as terminal, which loses the common case to protect the rare one. The
  backoff ceiling bounds the damage, and a carry-forward on `PLAN.md`'s flood-protection
  item records the better fix: an `ERROR` *before* 001 is far more likely to be a ban or
  a throttle than a dropped link.
- **One deadline covers connecting and registering.** They fail the same way and neither
  has a timeout anywhere below this layer, so splitting them would be two knobs for one
  question.
- **Nick candidates truncate rather than give up.** `alice` grows to `alice____` at the
  9-character default; a nick already at the limit still yields one variant because the
  base is truncated to make room for the underscore, where plain appending would produce
  an over-long nick and no candidate at all. The sequence terminates when truncation
  stops producing a new name, which needs no arbitrary attempt cap.

**Learned:**
- **Prompt 4's carry-forward was right about the hang and wrong about the cause.** It
  claimed a *refused* connection sits in `.waiting` forever. Measured, on loopback: a
  refused port fails in milliseconds, as `.failed(.receiveFailed("Connection refused"))`
  — through the *read*, not through a connection state. What really hangs is an
  unroutable address: `192.0.2.1:6667` stayed in `.connecting` for as long as it was
  watched, with no failure ever reported. The deadline is still necessary and is still
  the only thing that ends *that*, plus the case the note did not mention — a server
  that accepts TCP and then says nothing.
- **Which is why the deadline test now uses a silent server, not a dead port.** The
  first version raced NWConnection's refusal against a 200 ms deadline and passed only
  under load, which is the worst kind of test: green on the machine that wrote it. A
  scripted server with no rules accepts the connection and never answers, so the
  deadline is the only thing that can end the attempt. Deterministic, and it dropped the
  integration suites from 5.0s to 0.35s because nothing waits out a doomed timeout.
- **`NICKLEN` is unknowable during registration.** `ISUPPORT` arrives after 001 and 433
  arrives before it, so the fallback necessarily works from the RFC default of 9. The
  configured nick's own length is taken as a floor — the server answered "in use", not
  "erroneous", so a nick that long is evidently legal.
- **`dictionary[key] = nil` removes the key.** A valueless ISUPPORT token has to be
  stored as a present key with a `nil` value, which needs `updateValue(nil, forKey:)`.
  The subscript silently did the opposite, and `SAFELIST` would have read as absent.
- **`Mutex` being non-copyable bit again**, indirectly: the session keeps its
  cancellation state in actor properties rather than a shared box, which is simpler
  anyway once every callback path already hops to the actor.

**Measured:** 130 tests in 0.35s. The integration suites were run 8 times consecutively
after the deadline-test rewrite without a flake, and the full suite 3 times.

**Live check.** `CARAVAN_LIVE_TESTS=1 swift test --filter LiveRegistrationTests` connects
to `irc.libera.chat:6697` over TLS and registers for real: 001–004 captured, ISUPPORT
read back as `NETWORK=Libera.Chat`, `CASEMAPPING=rfc1459`, `NICKLEN` 16 or more, `@` in
`PREFIX`, non-empty `CHANMODES` group A. Passed in 6.7s. CI never runs it. A scripted
server proves the state machine does what the script says; only a real ircd proves the
script resembles an ircd.

**Carry-forward consumed:** all four notes on prompt 5, from prompt 4. The connect
deadline exists (and the note's claim is corrected above); one `IRCConnection` per
attempt is what reconnect does; `.failed` reconnects and `.cancelled` does not, tested
both ways; and the loopback server became a shared target rather than a copy. Notes
deleted.

**Carry-forward raised:** three on prompt 6 (the two streams it replaces, the
`.disconnected`-then-`.reconnecting` pairing, and when `.registered` should fire given
that 002–004 trail 001), two on prompt 7 (the Connect sheet maps to
`SessionConfiguration`; show the disconnect reason), one on prompt 8 (the
`ServerCapabilities` accessors it needs), and one on `PLAN.md`'s flood-protection item
(recognising a permanent `ERROR` instead of reconnecting into a ban).
