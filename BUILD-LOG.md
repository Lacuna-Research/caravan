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

---

## Prompt 6 — Typed event model

**Commit:** see PR  **Date:** 2026-08-05

**Shipped:** `IRCEvent`, `Target`, `EventTranslator` and `EventMulticaster`.
`IRCSession`'s two public `AsyncStream`s are gone, replaced by `events()`. 166 tests
across 23 suites; `make all` clean.

**Decisions:**
- **The translator is a pure function, separate from the session.** Given a message and
  the capabilities, it returns the events that message means. That is what makes the
  table-driven test the prompt asked for possible without a socket: 30-odd cases running
  in microseconds, where the same coverage through the session would need a scripted
  server per row. Session-driven events — `.stateChanged`, `.registered`,
  `.clientError` — stay in the session, because they do not come from a message.
- **`.registered` fires on 001, carrying what is known then.** This consumes prompt 5's
  open question. 001 *is* the protocol's definition of registered, and nothing marks the
  end of the 002–005 burst, so waiting for "the rest" would mean guessing at a boundary
  that does not exist. 002–004 refine `session.serverInfo` and surface as `.numeric`,
  which is also how a real client displays them — as lines of server text.
- **`.numeric` fires for every numeric without a more specific event.** So a status
  window renders the MOTD, 002–005 and every error numeric with no case per code. Only
  001, 353 and 366 are suppressed, and only because another event carries their whole
  content.
- **`bufferingNewest` per subscriber, so a stalled consumer loses its oldest events.**
  Documented on the multicaster. A chat window that fell behind should skip to what is
  happening now rather than replay history it can no longer act on; the `TraceBuffer` is
  where a complete record lives. The broadcaster never blocks and never waits on a
  subscriber, so one wedged consumer costs the others nothing.
- **No replay on subscribe.** A late subscriber sees what follows, not what it missed.
  Replay means an unbounded backlog or an arbitrary cut-off, and the session already has
  `state`, `serverInfo` and `capabilities` as properties for anything that needs the
  current picture rather than the history.
- **`Target` strips `STATUSMSG` prefixes.** `@#swift` is a message to the operators of
  `#swift` and belongs in that channel's window; without stripping, the leading `@` made
  the whole thing parse as a nickname. The distinction is not lost — it is in `.raw`.

**Learned:**
- **Suppressing `.numeric` by code was wrong, and a test caught it.** A 353 too short to
  name a channel produced no names event *and* no numeric, so it vanished — precisely
  the invisibility the raw guarantee exists to prevent, one layer up. Suppression is now
  conditional on a specific event actually being produced. The lesson generalises: a
  denylist of codes describes intent, but the condition that matters is whether the work
  actually got done.
- **Two of my own fixtures used one-digit numerics.** `:server 2 alice :text` is a
  *verb* named `2`, not numeric 2 — prompt 3's rule, working exactly as designed, on the
  person who wrote it.
- **Continuations must be copied out from under the lock before yielding.** `yield` and
  `finish` can run a termination handler synchronously, and that handler takes the same
  lock to unsubscribe. Holding it across the call is a deadlock that would only appear
  when a consumer went away at the wrong moment — which is to say, in front of a user.
- **CI found a race that had been latent in the test harness since prompt 4.** A client
  reaches `.ready` the moment TCP completes, which is *before* the loopback server has
  finished accepting — its listener callback still has an actor hop to make, and a line
  sent into that window goes to a nil connection and is dropped. Green on this machine
  for two prompts; red on a loaded runner. The transport harness now waits for the
  server to have accepted, and `ScriptedIRCServer.send` says so in its documentation.
  Scripted replies were never exposed to it, since a rule can only fire on a line that
  already arrived — which is why the session suites never flaked.

  Diagnosed from the log rather than reproduced: six concurrent test processes on this
  machine did not trigger it even with the fix removed. The evidence is nonetheless
  unambiguous — the harness's own `.ready` expectation passed, and *zero* inbound lines
  reached a fresh trace buffer in five seconds, which happens only if the server's
  connection was still nil when it wrote. Worth stating plainly that the fix is
  reasoned, not demonstrated, since "could not reproduce" is where flaky tests go to
  hide.

**Measured:** 166 tests in 0.36s, run 8 times consecutively without a flake. The
translator suite is 40 of those and needs no networking at all.

**Live check.** Both network-gated suites re-run against Libera after the refactor:
TLS handshake, certificate surfacing, and registration reading back `NETWORK=Libera.Chat`
through the new event stream. Passed.

**Also fixed:** three code comments still asserting that a *refused* connection leaves
`NWConnection` in `.waiting` forever. Prompt 5 measured that and corrected it in this
log, but left the comments saying the old thing. An unroutable address is what hangs.

**Carry-forward consumed:** all three notes on prompt 6, from prompt 5. Both streams are
replaced; the `.raw` guarantee now covers every message including the ones the session
handles itself, with a test for PING specifically; the `.disconnected`-then-
`.reconnecting` pairing survives and has its own test; and `.registered`'s timing is
decided above. Notes deleted.

**Carry-forward raised:** two on prompt 7 (subscribe before connecting since there is no
replay; render `.numeric` generically), two on prompt 8 (the membership events already
exist, so what remains is 332/333/331/324 and the join-failure numerics; `.modeChanged`
arguments are deliberately unparsed), and one on `PLAN.md`'s Queries & CTCP item
(`ACTION` is unwrapped, every other CTCP still renders as control characters).

---

## Prompt 7 — Minimal UI and the scrollback view

**Commit:** see PR  **Date:** 2026-08-05

**Shipped:** `CaravanUI` — `MessageLogController` and `MessageLogView` (the scrollback),
`LineRenderer`, `ConnectionViewModel`, `AppModel`, `RootView`, `ConnectSheet`. The app
target is now a `@main` and nothing else. 199 tests across 28 suites; `make all` clean.

**Deviations:**
- **A new target, `CaravanUI`.** Prompt 1 listed four library targets and this is a
  fifth. It exists because nothing inside an `.xcodeproj` app target is reachable from
  `swift test`, and this prompt's central requirement is a benchmark. The choice paid for
  itself immediately: the scrollback has 14 unit tests driving real `NSTextView`s
  headlessly, which would all have been impossible in `App/`.

**The benchmark, and the engine decision.** 50,000 lines of ~80 characters, appended in
bursts of 100, then scrolled top to bottom laying out each viewport. Apple M-series,
release of the debug build, one engine per process:

| | TextKit 2 | **TextKit 1** | TextKit 2 native |
|---|---|---|---|
| append | 1.00s (49.8k lines/s) | **0.93s (53.6k lines/s)** | 0.03s (1.59M lines/s) |
| full layout | 0.22s | **0.00s** | 0.62s |
| scroll, 876–1001 viewports | 1.54s | **0.00s** | 2.55s |
| slowest viewport | 85.3ms | **0.01ms** | 6.89ms |
| memory added | 589 MB | **25 MB** | 258 MB |

**TextKit 1, then**, which is what the prompt anticipated and asked to have justified.
The memory figure decides it on its own: 589 MB versus 25 MB for four megabytes of text
is not a tuning problem. TextKit 2's worst viewport at 85 ms is five dropped frames, and
its best case — appending natively through `NSTextContentStorage`, the third column —
still costs ten times the memory and moves the cost into scrolling, where the user is
watching. Append throughput was never the constraint: both are around 50k lines/second,
and a busy channel is three.

Revisit when: TextKit 2's memory per laid-out line comes down, or when something we want
(bidirectional text, better selection) only exists there. `MessageLogView` keeps the
engine as an init parameter and the benchmark measures both, so that is a one-line change.

**Decisions:**
- **The controller owns the text storage; SwiftUI never diffs it.** `updateNSView` does
  nothing at all. A `List` of messages was never a candidate — selection across lines,
  incremental append and honest scroll control are all things `NSTextView` does and
  `List` does not.
- **Trimming waits while the user is scrolled up.** Deleting from the top shifts
  everything below it, which is invisible at the bottom and a yank in the face when
  reading history. A ceiling of four times the cap keeps someone who scrolls up and walks
  away from growing the buffer without bound, and the trim happens the moment they come
  back down.
- **The input field sends raw IRC lines, as a stopgap.** Prompt 9 owns commands; a field
  that did nothing until then would have made the acceptance test impossible, and this is
  the smallest thing that is not a no-op.
- **Monospaced, `<nick> text`, no timestamps yet.** mIRC's line shape, which prompt 10
  fills out. `LineKind` is the single colour table it will grow into.

**Learned:**
- **`NSTextView.layoutManager` silently downgrades a TextKit 2 view to TextKit 1.**
  Merely *reading* the property does it. The first version of this benchmark printed a
  diagnostic that touched `layoutManager` before checking `textLayoutManager`, and
  therefore reported TextKit 1 for a view that had been TextKit 2 a microsecond earlier —
  measuring one engine while believing it was the other. There is now a test asserting
  exactly this behaviour, because it is the kind of thing that will otherwise be
  rediscovered the hard way.
- **`NSTextView(frame:textContainer:)` will happily build a view with no text system.**
  The text network is rooted at the `NSTextStorage`; build it in a helper, return only
  the container, and the storage deallocates on the way out. The view then has a nil
  `textStorage` and every append silently does nothing — which is what the first TextKit
  1 benchmark measured, at a very impressive 380,000 lines per second.
  `NSTextView(usingTextLayoutManager:)` is the initializer that selects an engine *and*
  leaves the view owning its own text system.
- **A font cannot go into an `AttributedString` under Swift 6**, because `NSFont` is not
  `Sendable`. `NSColor` is. The default font is applied on the AppKit side, filling only
  the runs that lack one so prompt 10 can still set bold and italic per run.
- **`waitUntil` needed `isolated (any Actor)? = #isolation`** to be callable from a
  `@MainActor` test — otherwise the condition closure has to cross an isolation boundary
  to reach a nonisolated helper, and main-actor state cannot come with it.

**Acceptance, met.** Connected to `irc.libera.chat:6697` over TLS and watched the full
MOTD render in the status window: monospaced, URLs auto-linked and clickable, the mode
line in teal, "Connected as caravan389817" in the status bar. Scroll-lock confirmed while
it streamed. The automated half of that is `LiveScrollbackTests`, which drives the real
`NSTextView` through the real pipeline and asserts the MOTD arrived, that the view held
its position while lines kept coming, and that the jump-to-latest affordance counts them
— 41 lines rendered on the run recorded here.

**Two latent test races surfaced, both from earlier prompts.** Adding 33 `@MainActor`
tests to the suite changed the contention enough to expose them, and CI found both:
- The timer-flush test slept a fixed 200 ms and asserted. Every suite in this target
  wants the main actor, so on a loaded runner 200 ms is not a guarantee of anything. Now
  polled.
- Prompt 5's ISUPPORT test read `capabilities` the moment the session reported connected.
  005 arrives *after* 001 — the test had been winning that race by luck since it was
  written. Now waits for the value.

Both are the same mistake: asserting on a fixed delay rather than on the outcome. The
polling helper existed already in both cases.

**Also learned, the embarrassing way:** the first three screenshots showed an empty
window and I went looking for a SwiftUI bug that was not there. Each worktree gets its
own DerivedData directory, and the path had been copied from a previous prompt's build —
so the app being launched was prompt 4's, which genuinely had an empty `ContentView`. Ask
`xcodebuild -showBuildSettings` for `BUILT_PRODUCTS_DIR` rather than remembering it.

**Carry-forward consumed:** all four notes on prompt 7. The Connect sheet collects
exactly the seven `SessionConfiguration` fields plus a password (not persisted — its home
is the Keychain); every disconnect reason is rendered, with a table-driven test that each
says *why*; the view model subscribes before connecting, and says so where it would
otherwise look like a stray ordering; `.numeric` is rendered generically, which is what
makes the MOTD appear without a case per code. Notes deleted.

**Carry-forward raised:** two on prompt 8, two on prompt 9, three on prompt 10.

**Noted, not acted on:** there is a parallel design conversation in another worktree
(`GUI-DESIGN-NOTES.md`, uncommitted) with settled decisions that touch this prompt — the
single-window sidebar model and the monospaced mIRC line shape, both of which this
matches, and a growing multi-line input box, which conflicts with prompt 9's "a paste
sends immediately" and is flagged there as a revision. That file is not a spec and is not
mine to fold in; it wants weaving into the prompts deliberately, by whoever owns it.

---

## Correction — the TextKit comparison was stated unfairly

**Date:** 2026-08-05  **Affects:** the prompt 7 entry; no code changes

The prompt 7 entry concludes with "The memory figure decides it on its own: 589 MB versus
25 MB". That pairs TextKit 1 against the *hybrid* — TextKit 2 driven through
`textStorage`, with both engines' machinery alive at once. That configuration is a
misconfiguration, not TextKit 2's best case, and it is not what we would have shipped had
we chosen TextKit 2. The table in that entry has the honest numbers; the sentence drawing
the conclusion from them picked the flattering pair.

**The fair comparison** is TextKit 1 against the native path, appending through
`NSTextContentStorage`:

- **25 MB versus 258 MB.** A tenfold gap, and the real argument.
- **Slowest viewport 0.01 ms versus 6.89 ms.** 6.89 ms is inside a 16.7 ms frame budget,
  so TextKit 2 native would still have scrolled at 60 fps. Not disqualifying, which "five
  dropped frames" implied of it — that figure belonged to the hybrid's 85 ms.
- **Total to ingest and display 50,000 lines: 0.93s versus 3.2s.** TextKit 1 lays out
  during append and TextKit 2 defers into scrolling, so the reported "scroll 0.00s"
  flatters TextKit 1 by measuring work it had already done.

**And the benchmark ran with the cap lifted**, to 200,000 lines, so all 50,000 stayed
resident. The app ships a 5,000-line cap. Scaled to what actually runs, that is roughly
2.5 MB against 26 MB — both unremarkable. **The choice was safe, not forced.** TextKit 1
was better on every axis measured and cost nothing to take, which is reason enough; but
had TextKit 2 won on something we cared about, memory would not have vetoed it at the
buffer size we ship.

**Instruments was never run.** The prompt asked for it. The signposter intervals are in
place and the numbers come from a programmatic harness reading `phys_footprint`, which is
the figure the memory gauge reports — but no trace was taken, so the memory is not
attributed to particular allocations the way a trace would show. The wall-clock and
throughput figures are unaffected.

**The decision stands.** Nothing here argues for TextKit 2; it argues that the margin was
overstated and the reasoning less forced than it read. `MessageLogView` keeps the engine
as an init parameter and the benchmark still measures all three paths, so revisiting is a
one-line change plus a rerun.

**Worth generalising:** the benchmark's own configuration — a lifted cap, a measurement
harness rather than the shipping one — is part of the result and belongs next to it. A
number without the conditions that produced it invites exactly the overstatement this
entry is correcting.

---

## Correction — prompt 7.5's brief was written against a stale copy of the notes

`PROMPT-7.5-GUI-DESIGN.md` was drafted while `GUI-DESIGN-NOTES.md` was still being
written, and captured it at roughly twelve sections of an eventual twenty. Its structure
was sound — the ordering before prompt 8, the separate file to avoid a brief that edits
itself, the carry-forward preservation counts, and the observation that `make check`
catches a note *outliving* its prompt but not one deleted *before* consumption. Those are
kept as they were.

Three things in it were wrong, and two would have caused real damage:

**It listed six settled decisions as open** — the palette toggle, nick-colour hash seed,
input box scroll-vs-grow, toolbar default, binding capacity and tree ordering — and
instructed the fold to file them in `PLAN.md`'s **Still open** list. All six were answered
after the draft was written. That instruction would have taken answered questions and
un-answered them in the one place the project treats as authoritative for unanswered
ones. Replaced with the opposite instruction, plus the distinction §20 draws between
*deferred* (nobody has to decide it, somebody has to build it) and *open*.

**Its input pointer was wrong.** It described the notes as uncommitted in a worktree; they
are committed and pushed on `gui-design-notes`. A brief pointing at a worktree path is
also fragile, since the worktree can be removed. Now reads from the branch via `git show`.

**Its conflict list covered §3–§12 and stopped**, missing six that the later sections
introduced. The largest is §15: the font choice was settled by measurement — Menlo over SF
Mono, because SF Mono lacks eleven of the forty-four CP437 art characters and CoreText
substitutes them from proportional fonts at up to 1.80x cell width. Also missing were the
Dashboard superseding a Connect sheet prompt 7 already shipped, the header bar generalising
prompt 8's topic bar, close-parts-the-channel, disconnect greying, and two prompt 10
defaults.

**Generalising:** a brief that summarises a document still being written will be wrong in
proportion to how much of it was still unwritten, and the failure is silent — a stale
summary reads exactly as confidently as a current one. The fix applied here is to make the
brief point at the source and say so: it now instructs the fold to check against all twenty
sections rather than against the brief. Prefer briefs that cite a stable ref over briefs
that restate content.

---

## Correction — three defects in prompt 7.5's brief, and a prune

**Date:** 2026-08-05  **Affects:** PROMPT-7.5-GUI-DESIGN.md; no code changes

Three problems, one of which would have destroyed shipped work:

**Merging `gui-design-notes` would revert prompts 6 and 7.** The branch forks from `main`
at `b9da1b7` and does not contain the five commits after it — roughly 3,500 lines. The
brief invited exactly that by asking whether the notes should "land on `main`" without
saying how. It now says to branch from `main` and copy the file across with `git show`,
and says plainly not to merge.

**A carry-forward under prompt 7 fails `make check`.** Conflict 6 asked for the font
decision to land "as a carry-forward on prompt 7's shipped `MessageLogView`". Prompt 7 is
complete, and the staleness check reports a note under a completed prompt as outliving it
— verified by probe when this file was first written. The brief's own SCOPE section had
the rule right; the specific instruction contradicted it, and an executor follows the
specific one. The note now goes on prompt 10, which next touches rendering, and SCOPE
says "never a carry-forward block under one" rather than leaving it implied.

**The font decision contradicts shipped code, and the fold does not fix it.**
`LineRenderer.font` returns `NSFont.monospacedSystemFont` — SF Mono, the font §15 rejects
on measurement. 7.5 is docs-only, so the app keeps rendering in SF Mono until prompt 10
runs. The brief now requires the decision entry to say so, because a merged fold that
records "Menlo, decided" invites the reader to assume the code follows.

**Also pruned.** The brief had accumulated four passages narrating its own correction
history — which draft was stale, what it had got wrong, which sections it had missed. All
of that is in the previous entry, which is where this project keeps reasoning; in the
brief it was noise between an executor and its instructions, and it made a summary look
like an argument. The substance those passages carried is kept: the six settled decisions
are still named, so the specific mistake is still warned against, without the archaeology
of who made it.

**Generalising:** a document that is corrected in place accretes a second document inside
itself, addressed to a different reader. Corrections belong in the log; the instruction
should read as though it had been right the first time.

---

## Prompt 7.5 — GUI design integration

**Commit:** see PR  **Date:** 2026-08-05

**Docs only — no `Sources/` change.** The twenty sections of `GUI-DESIGN-NOTES.md` are
folded into the queue and the plan: prompts 8, 9 and 10 rewritten in place, a new
prompt 11 appended, twelve `PLAN.md` items reshaped and one added, the brief
(`PROMPT-7.5-GUI-DESIGN.md`) and its pointer section deleted. The app's behaviour is
unchanged, and one consequence deserves stating before anything else: **the app still
renders in SF Mono.** §15 settles Menlo, on measurement; `LineRenderer.font` keeps
returning `monospacedSystemFont` until prompt 10 runs. A carry-forward on prompt 10
names the call sites, so a reader of the merged fold cannot assume the font changed here.

**The notes land on `main`, as the standing reasoning record.** Rejected alternative:
distribute the content into the prompts and leave the file on its branch as history. The
notes carry reasoning the prompts deliberately do not, and a branch is where documents go
to stop being found. The drift hazard of a second copy is real — this plan's own words
are "the copy nobody edits is the one that gets read" — so the file's preamble now says
what it is: folded on 2026-08-05, `STAGE1-PROMPTS.md` and `PLAN.md` authoritative for
what gets built and when, this file the reasoning they cite by section. Copied across
with `git show` — the branch forks from pre-prompt-6 `main` and must never be merged.
`Scripts/font-coverage.swift` came across the same way, because §15 says "rerun it
before revisiting" and a measurement you cannot rerun is a number, not an argument.

**The eleven rulings:**

1. **A paste never sends (§7) — prompt 9 rewritten.** Replaces "pasting multiple lines
   sends them as separate messages" immediately — which is mIRC's own behaviour, and is
   rejected because the content a paste puts on the wire can be a password or a key in a
   `PRIVMSG` body, where the `Redactor` by design cannot see it. Pre-send visibility is
   the only guard for that case. Both hard-won details survive in the prompt text rather
   than being left to the implementer: a trailing-newline paste is never Enter, and
   stage 3's paste-protection dialog (`PLAN.md` reworded) is a warning on an
   already-visible payload, not the last line of defence.

2. **One formatting seam, not two (§4) — prompt 10's colour table becomes the format
   table.** `LineKind`, shipped in prompt 7 as the colour table, grows into the
   declarative tier: a template string plus a colour per line kind, no JavaScript on the
   render path. Theming (`PLAN.md`, Themes — stage 3, where the Colors dialog lives)
   edits that one table; stage 2 builds no second colour surface over the same seam; the
   opt-in JS hook lands in stage 3 beside scripting. The old "stage 2 theming" phrase in
   prompt 10 mislabelled the stage and is corrected in the same breath. Rejected:
   keeping "colours in one table" and
   growing a separate format-string mechanism later — two seams for one job, which is
   exactly what the note warned against.

3. **The Debug & Settings canvas is a new prompt 11, not a prompt 10 absorption (§10).**
   Prompt 10 is already the largest prompt in the queue, and the canvas introduces a new
   kind of surface plus a pinned tree row — a concept, not a bullet. `/debug` moves to
   prompt 11 whole; splitting one command's semantics across two prompts was rejected.
   Prompt 10 keeps the status window (a buffer), its raw-traffic toggle and "Copy
   diagnostics". The stage closeout moves to prompt 11, which is now last. Ejection to a
   standalone window is deferred to stage 2's Multi-window item so it ships as the same
   affordance that detaches a buffer — a scheduling call on a settled design, not a
   reopening of it.

4. **Sidebar (§3, §9, §12): the tree's *shape* is stage 1, moving through it at scale is
   stage 2.** Prompt 8 builds what the tree is — buffers nested under their network,
   the network row doubling as the status buffer's entry (prompt 7's separate status row
   folds away), every row an ordinary selectable row, monospaced, `#` sigil, join order,
   and the §16/§17 greyed not-joined state. Stage 2's Multi-window item gets the four
   activity states with highlight badges, collapsed-group rollup, next-unread and
   next-highlight keys, MRU Ctrl-Tab and drag-to-reorder. Rejected: activity states in
   stage 1 — they need unread tracking prompt 8 otherwise has no reason to build, and
   with one network and a handful of buffers they would be decoration. Prompt 8's "Do
   not" fence now names all of it. (Also settled while here, because the fence made it
   visible: `/query` predates the fold and stage 1 has no query buffers, so prompt 9 now
   defines it as behaving like `/msg` until stage 2's Queries item gives it its window,
   and prompt 10's acceptance says PMs render in the network's status window until then.
   Rejected: dropping `/query` from stage 1 — it would fall through the raw passthrough
   and reach the server as an unknown QUERY command, which is worse than a useful alias.)

5. **Bindings (§11) and the quick-switcher (§9) are stage 2, said in `PLAN.md` rather
   than left in a notes file.** The Multi-window item now carries the full settled
   model — nothing bound by default, `Bind to ▸ 1…9` in the context menu, digits shown
   in the tree, nine global slots, buffer-identity attachment, plain-text persistence,
   ⌘0 reserved, closed targets opened with the connected-network guard.

6. **Fonts (§15) — prompt 10 text plus a carry-forward, and the script joins the repo.**
   Menlo over SF Mono (eleven of forty-four CP437 art glyphs missing, substitution up to
   1.80x cell width), the explicit monospaced-only cascade, ligatures off,
   ambiguous-width narrow, line height clamped, VS16-only emoji presentation: all now in
   prompt 10's text. Density, zoom and the force-grid toggle are settings, so they land
   in stage 2's Options item; per-buffer fonts in stage 3 Themes; the VoiceOver floor in
   stage 4 Accessibility. Restated: **the code contradicts this decision until prompt 10
   runs.**

7. **The Dashboard (§13) is a `PLAN.md` reshape, not a stage 1 retrofit.** The Server
   list item becomes "Server list — the Dashboard": a canvas, peer row above the
   networks, the splash screen and empty state, first run lands there, and it replaces
   prompt 7's Connect sheet — named in the item as shipped code to retire
   (`ConnectSheet` in `CaravanUI`), because a plan that says "replaces" without saying
   "there is code" invites a second sheet. Rejected: replacing the sheet in stage 1 —
   it works, stage 1 has one network, and the front door earns its keep when the server
   list exists. Statistics stay deferred, as a new stage 4 item.

8. **The header band (§14) generalises prompt 8's topic bar.** Channel/topic case in
   prompt 8, network/MOTD case in prompt 10 — where the shrink behaviour is called
   load-bearing, since the MOTD is the long one — and the query/context case in stage
   2's Queries & CTCP item, which cites §14 and takes its wording when built. Rejected:
   a channel-only topic bar, and any dismissible band — a header that can be dismissed
   is one people dismiss once and then forget exists. The never-hidden, never-closable
   rule is stated in both prompts' text.

9. **Buffer lifecycle (§16): the invariant lands in prompt 8 and prompt 9 both.**
   Membership never outlives its buffer; a buffer may outlive membership. Prompt 8:
   closing a channel buffer (⌘W, named so the rule is testable) parts the channel, and a
   parted or kicked channel keeps its buffer in the greyed state. Prompt 9: `/part` is
   not a close. One new test named in prompt 8: a KICK of ourselves leaves the buffer
   open. Rejected, both symmetric alternatives: `/part` closing the buffer throws away
   scrollback you may want to read back or rejoin from, and close leaving membership
   creates a joined channel with no window — the invisible "ghost" §16 exists to forbid.

10. **Disconnect greying (§17) — prompt 8.** A disconnected network keeps its buffers in
    the tree, in the *same* not-joined visual state as a parted channel. One "you are
    not in here right now" appearance, not two.

11. **The §19 defaults, checked and placed.** Into prompt 10: timestamps `[HH:mm:ss]`
    dim in a fixed-width column, and the unread marker persisting until the buffer is
    next left — moved out of stage 2's Buffer utilities, which shrank accordingly. The
    rest audited against what exists: the nick list (prompt 8) gains collapsible and an
    app-wide persisted width; jump-to-latest and scroll-lock match what prompt 7 already
    shipped, no change; first run lands on the Dashboard, stage 2.

**Carry-forward accounting.** All ten pre-existing notes preserved verbatim — five on
prompt 8, two on prompt 9, three on prompt 10 — and the three on `PLAN.md` items
(Queries & CTCP, Flood protection, Authentication) untouched. None superseded: the §4
ruling *extends* prompt 10's "LineKind is the one-table seam" note rather than replacing
it. One raised: prompt 10, the SF Mono call sites.

**Adding prompt 11 took the four mechanical edits** — `TOTAL_PROMPTS=11`, the status
line at 7/11, the README badge and an eleventh table row — plus the prose that restated
the count: the queue's title ("The Ten Prompts" → "The Prompts"), and "ten prompts" in
`PLAN.md` and the README. A count restated in prose is a count that goes stale.

**Pruned, since the fold touched the lines anyway:** stage 2 Buffer utilities loses
scroll-lock and jump-to-latest (shipped in prompt 7) and the unread marker (prompt 10);
stage 4 Diagnostics loses the raw-traffic debug window (stage 1 now ships it twice
over); stage 3 Customization loses the toolbar editor (`NSToolbar`'s palette is that
feature, §8). Left alone: the README mockup, which predates the notes and is owned by
the art generator; it gets redrawn when the real UI exists to draw.

**Still open: nothing.** §20 answers every question its conversation raised, and this
fold raised none — the six that look open (palette toggle, hash seed, scroll-vs-grow,
toolbar default, binding capacity, tree ordering) all carry their answers in the notes,
and `PLAN.md`'s list stays empty. The five deferred-not-undecided items landed as plan
entries: switchbar (Customization), Dashboard statistics (new stage 4 item),
notifications interface (Highlights & notifications), per-buffer fonts (Themes),
VoiceOver over the scrollback (Accessibility).

## Prompt 8 — Channel and user state

**Commit:** see PR  **Date:** 2026-08-05

**Shipped:** `IRCSession` — `Channel`/`Member`/`Topic`, `ModeChange`/`ModeParser`,
`ChannelRoster`, and five new events (`.topicAuthor`, `.channelModes`, `.joinFailed`,
`.channelChanged`, `.channelClosed`); `.modeChanged` now carries parsed changes.
`CaravanUI` — `ChannelBuffer`, `SidebarTree`, `ChannelBufferView`, `BufferChrome`
(`ScrollbackView`, `HeaderBand`, `ResizeHandle`). 254 tests across 31 suites; `make all`
clean.

**Two defects the live run found that no test could have.** Both are SwiftUI view
lifecycle, and both were invisible with prompt 7's single buffer:

1. **Switching buffers blanked the scrollback.** A buffer's text lives in its
   `NSTextView`'s storage, and SwiftUI destroys a representable's `NSView` whenever it
   leaves the screen. `makeNSView` built a fresh, empty one on the way back.
   `MessageLogController` now owns its scroll view (`displayView(usesTextKit2:)`), built
   once and handed back — which preserves the scroll position too, as switching back to a
   window should. Three regression tests.
2. **One channel's scrollback under another channel's topic and nick list.** With the
   view owned, SwiftUI still *reused* the representable across the switch — same type,
   same position in the hierarchy — so it called `updateNSView`, which does nothing, and
   left the previous buffer's view installed. Fixed with `.id(ObjectIdentifier(log))` on
   the representable. There is no headless test for SwiftUI view identity; the live run
   is the test, and the reasoning is in the comment at the fix.

Also found by (1): a buffer that has never been on screen queued its lines forever and
without bound. `flush()` now trims the pending queue to the same line cap, so a busy
channel joined and never clicked on cannot grow the process.

**Decisions:**
- **The session broadcasts whole `Channel` snapshots, not per-change events.** One
  `.channelChanged(Channel)` after the event that caused it. The alternative — a case per
  kind of change — puts the transition logic in every view that draws a member list, and
  two copies of it eventually disagree. Cost is copy-on-write: a netsplit copies the
  member dictionary once per departing user. Measured at 2,000 members it is not close to
  mattering; revisit if a snapshot ever shows up in a profile.
- **The event order is part of the contract.** The event first, then the snapshots. A
  buffer renders the `QUIT` line and *then* redraws its nick list — and routing a `QUIT`
  to the right windows is only possible because the UI's snapshots still contain the user
  when the line arrives.
- **`.modeChanged` carries parsed `ModeChange`s and *not* the raw arguments.** Two
  representations of one thing invite them to disagree; `.raw` already guarantees nothing
  is lost. An undeclared mode is assumed to take no argument — the failure that stays
  local, where the opposite guess swallows the next mode's argument and mis-parses the
  rest of the line.
- **`ServerCapabilities` gained an RFC 2811 default for `CHANMODES`.** An empty table is
  not neutral: a server that omits the token and then sends `+k hunter2` leaves the key
  unconsumed and desynchronises everything after it. Revisit only if a server is found
  whose unstated modes differ from RFC 2811's.
- **331 is an empty topic, not an event of its own.** It is the same thing a `TOPIC` that
  clears one sends, and one representation of "no topic" beats two. The renderer says
  "No topic is set for #x" rather than printing an empty string after a colon.
- **A casemapping or `PREFIX` change re-keys the roster.** `IRCNick`/`IRCChannelName`
  compare only within one mapping — that is what makes them safe keys — so a reconnect,
  which resets `ISUPPORT`, would otherwise leave carried-over channels unable to match
  themselves. Rejected: dropping the channels instead, which is exactly the vanishing
  tree §17 forbids.
- **`Topic.setAt` is Unix epoch seconds, not a `Date`.** `IRCSession` has no Foundation
  dependency and formatting belongs where the locale is known. A topic changed while we
  watch has no timestamp at all: the session has no clock, and the buffer's own line
  already carries the time.
- **`closeChannel` lives on the session, not just the view model.** It is the only thing
  that removes a channel from the roster, so the invariant — membership never outlives
  its buffer — is enforced below the UI rather than by convention above it.
- **The nick list pane runs the full height, beside the input field.** Taken without
  asking; the alternative (input spanning the full width) is equally common in real
  clients. Trivially reversible if it reads wrong in use.
- **⌘W is a disabled-when-inapplicable toolbar button.** With no channel selected the
  shortcut falls through to the window's own Close, which is what makes a status window
  non-closable without a special case: it is the network row, and closing a network is
  disconnecting from it.

**Learned:**
- **A `PART` echo arriving after its buffer is closed lands in the status window.**
  Visible in the live run as `*** Parts: <us> #caravan-smoke` after ⌘W. That is the
  fallback rule working — nothing a server says is dropped — rather than a bug, but it is
  the kind of line that looks like one.
- **`ChannelBuffer.id` has to be `nonisolated`.** `Identifiable` is not main-actor
  isolated, and a computed `id` on an `@MainActor` type fails the conformance under Swift
  6. The identity is an immutable `let`, so reading it off the actor is sound.
- **The `DisclosureGroup`-in-`List` tree is a real `NSOutlineView`,** and a `.tag()` on
  its label makes the network row selectable exactly as an ordinary row — which is what
  §12's "no header-styled rows" rule needs and what was least certain going in.

**Live acceptance:** connected to `irc.libera.chat:6697` over TLS, joined `#libera`
(1,748 members) and `#caravan-smoke`, switched between them and the status window,
`PART`ed one and ⌘W-closed the other. The parted channel kept its row, greyed; the closed
one sent `PART` and vanished. Nick list ordered by `PREFIX` rank with `@` prefixes, topic
and its 333 attribution rendered in local time, and the MOTD intact in the status window
after every switch.

**Carry-forward:** consumed all five notes on this prompt. Prompt 5's
(`ServerCapabilities` already has `rank(ofPrefix:)`, `channelModes`, `caseMapping`) and
prompt 6's two (the membership events exist; 332/333/331/324 and the join failures did
not; `.modeChanged` was unparsed) were acted on exactly as written. Prompt 7's two (a
buffer is a controller plus a view, already per-buffer; `LineRenderer` already renders the
membership events) were both correct and made the UI half far smaller than it looked —
though "a channel window is a second controller, not a rework" turned out to be true only
after the two view-lifecycle defects above were fixed. Raised: two notes on prompt 9 and
two on prompt 10.

## Prompt 9 — Command line

**Commit:** see PR  **Date:** 2026-08-05

**Shipped:** `IRCSession` — `CommandParser`, `CommandAction`, `CommandError`. `CaravanUI`
— `InputState` (per-buffer text and history), `InputField`/`InputTextView` (the real input
box), `InputBar`, and `AppModel.submit`. Prompt 7's raw-line stopgap is gone. 301 tests
across 34 suites; `make all` clean.

**The defect the live run found, and the one only a live run could.** In an `NSTextView`
that is not a field editor, **Shift+Return arrives as `insertNewline:` — the same selector
as plain Return.** The override sent on both, so the multi-line box could never be built:
typing `line one`, Shift+Enter, `line two` put two messages on the wire instead of one
two-line box. Fixed by consulting the modifier, through an injectable
`InputTextView.modifierFlags` seam so the regression has a test. The seam exists because
`doCommand(by:)` does not carry the flags and `NSApp.currentEvent` is not something a test
can set — a narrow test-shaped affordance, bought with a bug that shipped once.

Two hours of the live run also went to launching the *wrong* binary: `DerivedData` is
keyed on the project path, so each worktree gets its own, and the path memorised from
prompt 8 was still there and still ran. `xcodebuild -showBuildSettings | grep
BUILT_PRODUCTS_DIR` is the answer; the symptom was watching prompt 8's behaviour and
believing it.

**Decisions:**
- **The parser is pure and lives in `IRCSession`.** It produces `[CommandAction]` and
  neither sends, connects nor draws. That is what makes the command table a table —
  twenty-six tests running in a millisecond with no socket — and it is the same shape
  `EventTranslator` already took, for the same reason.
- **One switch over the actions, on `AppModel`.** `/server` points the *app* at a new
  host and a connection cannot replace itself, so splitting the switch across the two
  would leave an unreachable case in each. Rejected: a delegate closure on the connection,
  which is the same coupling with more indirection.
- **Leading whitespace is never trimmed; trailing whitespace always is.** ASCII art is a
  correctness constraint in this client (§15), and a leading run of spaces is load-bearing
  in it. The consequence — a line starting with a space is a message rather than a command
  — is the right way round.
- **`/join swift` gains its `#`.** From `CHANTYPES`, not a hardcoded prefix. `JOIN swift`
  is only ever an error, so there is nothing to lose by qualifying it.
- **An undeclared `/command` is uppercased and sent verbatim**, mIRC's passthrough, which
  is what makes the client useful for everything stage 1 has not wired up. A trailing
  parameter with spaces needs its own `:`, exactly as in `/raw` — the same bargain mIRC
  makes.
- **`+port` means TLS on `/server`; a bare port says nothing.** Twenty years of mIRC for
  the first half. The second half is deliberate: inferring TLS from the port number sends
  a password in clear when the guess is wrong.
- **`/quit` is one action, not `send` plus `disconnect`.** The order matters — a caller
  that got it backwards would write `QUIT` into a closed socket — and the disconnect is
  not merely tidy: a server answers `QUIT` with `ERROR` and closes, which the session
  would otherwise read as a failure worth reconnecting from.
- **The `>>` echo stays for now.** Prompt 10 owns local self-echo and the raw-traffic
  toggle, and `>>` markers are where that toggle's output belongs. Replacing it here would
  be doing prompt 10's work with none of its context.
- **`InputState` is per buffer, both halves.** History and the in-progress line. A history
  on the view would offer the wrong window's commands; a draft on the view would be lost
  on every glance at another channel.

**Learned:**
- **`wireForm` marks a trailing parameter only when it must** — empty, containing a space,
  or starting with `:`. `PRIVMSG #swift hello` and `PRIVMSG #swift :hello` are the same
  message. Half the first draft of the command table asserted the wrong one.
- **Every route into the text view funnels through `readSelection(from:)`.** ⌘V,
  paste-and-match-style, drag, services. Making `paste(_:)` call it rather than duplicating
  the sanitizer means the security rule has one implementation *and* can be tested without
  touching the user's real clipboard.
- **A `@MainActor` nested type in a test suite does not inherit the suite's isolation.**
  Both new UI harnesses needed `@MainActor` of their own.

**Live acceptance:** connected to Libera over TLS. `/join caravan-smoke` gained its `#`;
plain text in the status window printed the no-target error and put nothing on the wire;
`/msg` printed its usage line in the window it was typed in. In the channel, Shift+Enter
grew the box to three lines, a paste ending in a newline landed inline and sent nothing,
one Enter then sent three separate `PRIVMSG`s in order, and Up recalled the whole
three-line entry. `/quit that is all` left the network disconnected and greyed, its
channel buffer still in the tree, with no reconnect after fifteen seconds.

**Carry-forward:** consumed all five notes on this prompt. Prompt 7's two (the stopgap is
the seam; reuse `.clientError` for usage errors) and prompt 8's three (the target is
already threaded through; `/part` must not go through `closeChannel`; the in-progress line
needs the same per-buffer treatment as the history) were all acted on as written — the
`/part` one in particular is now a test that asserts the buffer count is unchanged.
Raised: two notes on prompt 10.

## Correction — a test fixture shaped like a real credential

**Date:** 2026-08-05

The paste test in prompt 9 used `-----BEGIN PRIVATE KEY-----` as its payload: the header
line alone, no key material. The secrets job flagged it as a private key, and it was
right to — not because the string is dangerous, but because `CLAUDE.md` requires a fake
credential in a fixture to be *recognisable* as fake, and that one is not. A scanner
cannot tell the difference, and neither can a reader skimming a diff.

The fixture is now `s3cr3t-not-real`. The test reads the same and the comment still names
the scenario it guards against.

**A new file: `.gitleaksignore`.** `gitleaks git .` scans full history, so the superseded
commit keeps failing the check on this branch however the working tree looks. The
alternatives were rewriting the branch — which the working method does not do — or
abandoning the PR. One fingerprint, with the reason beside it and an instruction to delete
it once this branch is squash-merged and the commit is gone. The file's header states the
rule for anything added later: an entry is a claim about a specific finding, and it needs
a reason.

Worth saying plainly, since it is the second time this project has learned it: the
mechanical check found what review did not. The fixture was written, read and committed by
someone who knew the rule it broke.

## Prompt 10 — Status window, timestamps, and line rendering

**Commit:** see PR  **Date:** 2026-08-05

**Shipped:** `CaravanUI` — `ChatFont`, `LineFormat`/`LineKind`/`LineColour`/`LineFormatTable`,
a rewritten `LineRenderer`, `ChatSettings`, `DiagnosticsReport`, the unread rule in
`MessageLogController`, local self-echo, the raw-traffic toggle, the status window's MOTD
band, and window titles. `IRCSession` — `EventTranslator.unwrapAction` made public for the
echo path. 329 tests across 36 suites; `make all` clean.

**The font measurement, rerun before shipping the decision.** `Scripts/font-coverage.swift`
at 13pt, unchanged from §15.1:

| Font | cell | Box Drawing | Block Elements | Geometric | CP437 art set | Off-grid |
|---|---|---|---|---|---|---|
| **Menlo** | 7.827 | **100%** | **100%** | **100%** | **44/44** | **none** |
| SF Mono (`monospacedSystemFont`) | 8.036 | 100% | 100% | 14% | 33/44 | none |
| Andale Mono | 7.801 | 31% | 25% | 15% | 44/44 | none |
| Monaco | 7.801 | 8% | 6% | 2% | 13/44 | 1 |

Menlo it is. The eleven SF Mono is missing are `▬ ► ◄ ☺ ☻ ♠ ♣ ♥ ♦ ♪ ♫`, and
`ChatFontTests` now asserts each of them has a glyph — the measurement turned into a
regression test, because the failure it guards against is silent: swap the family and
every one of those still renders, just up to 1.80× cell width.

**Decisions:**
- **One table holds the template *and* the colour.** `LineFormatTable` maps a `LineKind`
  to a `$variable` template plus a colour role. Stage 3's Colors dialog and stage 2's
  themes both reach for this, and a theme that could change the colour but not the wording
  would have sent them looking for a second seam. No JavaScript on the render path — a JS
  call per line cannot hit the ingest target, and the opt-in hook is stage 3's.
- **`DateFormatter` patterns, not `strftime`.** The prompt says "strftime-style" but its
  own default, `[HH:mm:ss]`, is written in ICU syntax — so ICU it is, and the brackets pass
  through as literals. A deviation from the words, matching the example.
- **The timestamp is dimmed by range, not by search.** `expand` reports where it landed.
  Searching the rendered line for the time would find the wrong digits the first time
  someone is called `12:00:00`.
- **Colours are semantic roles, not RGB.** `.text`, `.dim`, `.event`, `.error` and so on
  map to system colours, which adapt to light and dark without a table per appearance.
  Stage 2's mIRC palette work adds the indexed colours beside them.
- **The `own*` line kinds are the self-echo mark.** One enum case per shape rather than a
  flag beside the kind: `isSelfEcho` is then a switch over kinds, and stage 2 suppressing
  the duplicate when `echo-message` is negotiated is a filter rather than an excavation.
- **The raw toggle streams from the moment it is turned on.** It does not retroactively
  interleave what came before, and turning it off does not remove what was shown. mIRC's
  `/debug` behaviour, and prompt 11's `-i` flag is what reaches back into the ring.
- **Raw lines are redacted on the way to the screen.** The trace already redacts on
  insert; the toggle renders `Redactor.redact` output for the same reason, so the raw view
  cannot become the one place a `PASS` appears in plaintext. Verified live.
- **The unread rule is 400 `─` drawn with a clipping paragraph style.** Measuring the
  window instead would be wrong the moment it was resized; clipping makes an over-long
  rule span whatever width there is. Tracked by *line index* rather than character offset,
  because trimming from the top moves every offset below it.
- **`AppModel` moved into `CaravanApp`.** A `@State` inside a view does not reach
  `.commands`, and "Copy Diagnostics" is a menu item. `RootView` takes the model now.
- **`ChatSettings` persists to `UserDefaults`, injectably.** The same stopgap shape the
  Connect sheet uses; prompt 11 moves both to the plain-text config. Injectable because
  the first version of the new tests wrote into the preferences of whoever ran them.

**Learned:**
- **A bare `foregroundColor` on an `AttributedString` run resolves to SwiftUI's `Color`**
  when both attribute scopes are imported. `run.appKit.foregroundColor` is the one that
  compares against an `NSColor`.
- **`osascript keystroke` mangles non-ASCII.** The first attempt to type CP437 art into
  the running app produced a row of `a`s, which looked exactly like a font failure. Pasting
  through the clipboard is the way to get art into a GUI under automation.
- **`DerivedData` is keyed on the project path**, so every worktree gets its own. Prompt
  9's entry says this; it cost time again here before the lesson took. `xcodebuild
  -showBuildSettings | grep BUILT_PRODUCTS_DIR` is the answer, and it is now the first
  thing to run before any live check.

**Live acceptance, against Libera over TLS:** connected; joined two channels; held a
conversation in both; sent an action; sent a PM and received one (self-addressed, so it
arrives twice — once as the local echo and once as the server's delivery, which is correct
for that case and not for any other); used `/whois` through the raw passthrough; pasted a
CP437 art line and watched every glyph render with `!=` and `->` unligatured; turned on the
raw toggle and saw `>>`/`<<` in both directions with `PASS <redacted>`; copied diagnostics
to the clipboard and confirmed no plaintext credential; `/quit` and `/connect` cleanly,
with both channel buffers surviving greyed and the unread rule sitting exactly where the
buffer had been left. Not covered live: watching another person join and quit, which needs
a second party — the rendering is unit-tested and prompt 8's run exercised the events.

**Carry-forward:** consumed all seven notes on this prompt. Prompt 7's three (the
`LineKind` table is the seam; `.raw` renders nothing until the toggle exists; a font cannot
go into an `AttributedString`) shaped the whole design. Prompt 7.5's — the SF Mono call
sites, including the four `.system(.body, design: .monospaced)` modifiers prompt 8 added —
is now zero call sites: `grep` for that modifier returns nothing, and the chat font travels
by environment value. Prompt 8's two and prompt 9's two were each acted on as written; the
`>>` echo is gone from the buffer and lives only behind the toggle, and the input box's
six-line measurement still measures six in Menlo. Raised: three notes on prompt 11.

## Correction — two flaky tests, one mistake

**Date:** 2026-08-05

Both found while landing prompt 10, and both the same error: **comparing a snapshot of a
live stream against something that is still moving.**

One was new. `StatusWindowTests` asserted that `/who` left the status window *unchanged*,
to prove that only messages are echoed locally. The window does change — `WHO`'s numeric
replies land in it — and the test only passed on a machine slow enough that they had not
arrived yet. CI is not that machine. It now asserts the property it meant: no line
attributed to us, contrasted in the same test with a `/msg` that does produce one.

The other was prompt 6's, and had been latent since. `SessionEventTests` compared two
consumers' whole event logs after waiting for `.registered` to appear in each — but the
feed keeps running between the two `snapshot()` calls, so the second can hold an extra
005. It now compares the events up to and including registration, which is what the
multicast actually promises: every consumer sees the same events in the same order.

The general rule, since this is twice now: **wait on the thing being asserted, and assert
a property rather than an equality against a moving target.** A test that says "nothing
else happened" about a live connection is a test that will fail on someone else's machine.

## Prompt 11 — Debug & Settings canvas

**Commit:** see PR  **Date:** 2026-08-05

**Shipped:** `CaravanUI` — `ConfigFile` (the plain-text config), `DebugController`,
`SettingsDebugCanvas`, the `settingsAndDebug` sidebar row, `restyle()` and an eager
`lineCap` trim in `MessageLogController`, and `ownPrivateMessage`/`ownPrivateNotice` in the
format table. `Diagnostics` — `TraceBuffer.feed(includingRetained:)` and `TraceFileWriter`.
`IRCSession` — `/debug` and `CommandAction.debug`. `ChatSettings` and `ConnectionSettings`
moved off `UserDefaults`. 372 tests across 38 suites; `make all` clean.

**Decisions:**

- **The config file is line-preserving, not serialize-the-whole-model.** `ConfigFile` keeps
  the file as lines and rewrites only the line belonging to the key being set, so comments
  and keys from a later version survive a write. The alternative — decode, mutate, encode —
  is less code and silently eats anything it does not understand, which makes
  "user-editable" a claim rather than a property. Revisit if the format ever grows
  structure that lines cannot express.
- **An absent key means the default; it is not written out eagerly.** So the file stays as
  short as what the user actually changed, and a default that improves later improves for
  everyone who never touched it. `set(nil)` deletes the line, which is what makes "reset to
  default" expressible.
- **No migration from `UserDefaults`.** The app is unreleased and the stranded values are a
  host, a nick and a font size, re-entered once. A migration path is code that must then be
  carried and eventually deleted; the trade is worth it only for shipped software.
- **`/debug` gained a sink watermark rather than a replay-and-hope.** One rule covers the
  live feed and `-i`: a sink is only given events newer than the newest it has. So `-i`
  fills exactly the gap left while output was off, asking twice adds nothing, and clearing
  the canvas — which resets the mark — lets `-i` bring the whole ring back. The first
  version replayed the snapshot unconditionally and duplicated whatever was already there.
- **`TraceBuffer.feed` returns retained events *and* the live stream under one lock.**
  Snapshot-then-subscribe has a window in which an event is dropped or delivered twice; one
  atomic call has none. The retained events come back as an array rather than being replayed
  through the stream, so their order is the caller's rather than a race.
- **Both the canvas and `/debug` drive one piece of state.** The Streaming switch *is*
  `/debug window` / `/debug off`. A UI and a command that each held their own idea of where
  output was going would eventually disagree, and the user would be right either way.
- **⌘, and ⌘0 are two menu items, not one.** SwiftUI allows one shortcut per button, so the
  app menu carries "Settings & Debug…" (⌘,, replacing `.appSettings`) and View carries
  "Settings & Debug" (⌘0). Two items in *different* menus is findable; two in the same menu
  would not be.

**Learned:**

- **`didSet` that assigns to its own property is a stack overflow under `@Observable`.**
  The macro turns a stored property into a computed one, so the self-assignment re-enters
  the setter rather than being the no-op it is on a plain stored property. It crashed the
  whole test binary with SIGSEGV and no failing-test name. Clamping now writes back once and
  `return`s, which terminates because clamping a clamped value is a fixed point.
- **A font setting has to restyle text that is already on screen.** `MessageLogController`
  filled the font at flush time only, so changing it left the buffer in two fonts. `restyle()`
  reapplies over the whole storage — and has to put the clipping paragraph style back on the
  unread rule, which is deliberately wider than the window.
- **macOS will not foreground a second instance of the same bundle**, so `keystroke` cannot
  be aimed at one. The acceptance run's second party is a 60-line Python TLS client instead,
  which was both more reliable and able to cover the join/quit case prompt 10 could not.

**Live acceptance, against Libera over TLS:** connected; the Connect sheet pre-filled from
the seeded plain-text config, which is the `UserDefaults` move proved end to end; joined two
channels; held a conversation; sent an action; sent a PM and received one; **watched a real
third party join, speak and quit** — the gap prompt 10's run left open; `/whois` through the
raw passthrough; ⌘, and ⌘0 both opened the canvas with the tree still visible; `/debug`,
`/debug off`, `/debug -i window` and `/debug -i <file>` all behaved, the file carrying its
banner, the whole ring from before `/debug` was issued, and then live traffic; raised the
font size in the form and watched every buffer restyle live; confirmed the config file had
gained exactly one line and kept its hand-written comment; `/quit` and `/connect`, with the
channel buffer surviving greyed, the header band saying "You are not in", and the unread
rule where it was left.

**The run found one defect, fixed here.** `/msg bob hi` typed in `#swift` echoed as
`<@you> hi` — indistinguishable from something said in the channel. The message went to bob;
rendering it as a channel line is the client lying about where your words went. Now
`-> *bob* hi`, mIRC's form, with the recipient in the nick column; `/notice` likewise. The
echo stays in the window you typed in, which is mIRC's behaviour and the only way to see
that it sent without leaving the window. Stage 2's query buffers change the destination, not
this rendering.

**Carry-forward:** consumed all three notes on this prompt. Prompt 10's first — move *both*
`ChatSettings` and `ConnectionSettings`, or the Connect sheet's values stay behind — was
acted on, and then some: a grep for the note's two names left a *third* store behind, the
nick list's width and visibility in `@AppStorage`, so those moved too. One persistence
mechanism is the point of the move; a second store left behind is a second place to look
when a setting does not stick. `UserDefaults` and `@AppStorage` now appear nowhere in
`Sources/` or `App/` outside two comments explaining what they used to be. Its second and third
were right that the debug half's rendering and the redacted export were already built, so
this prompt added destinations and `-i` rather than rendering. Raised: two notes on stage 2
items in `PLAN.md`.

## Decision — stage 1 retrospective

**Date:** 2026-08-05

Eleven prompts, one PR each, 372 tests, zero external dependencies. What the stage actually
taught, as opposed to what the plan assumed:

**The mechanical checks earned their keep, and they earned it by failing.** `check-docs.sh`
caught a stale README badge, an unconsumed carry-forward note and a missing build-log entry
across the stage — each one a promise that a human reviewer had already read past. The rule
worth keeping: when a convention proves important, make it mechanical rather than writing it
more emphatically. The corollary this stage found is that the *cheap* checks are the ones
that keep working; every check here is a `grep` or a line count.

**Carry-forward notes were the highest-leverage documentation invention.** Nine of the
eleven prompts either raised or consumed one, and in the two cases where a note was
specific enough to name a symbol (`LineKind` is the seam; move *both* settings stores) the
downstream prompt was materially shorter for it. A note that says "remember to think about
X" is worth little; one that names the file and the function is worth a session.

**Purity paid, and it paid at the point of testing.** `IRCProtocol` and `CommandParser` hold
the two biggest tables in the codebase, and both are exhaustively tested without a socket
because neither can do I/O. The Linux CI job is the reason that stayed true rather than
eroding — it fails mechanically the moment an `import` slips in.

**Three defects reached a live run rather than a test, and all three were about *what the
user sees*, not about state:** prompt 8's scrollback drawn under the wrong channel's chrome,
prompt 10's `>>` echo in the wrong buffer, and this prompt's `/msg` echo rendered as a
channel line. The state machine underneath was correct in all three. The lesson for stage 2:
a live run is not a formality at the end of a prompt, it is the only test that looks at the
window — budget it, and script the second party rather than needing a human.

**Two tests were flaky, both for the same reason**, recorded in their own correction entry:
comparing a snapshot against a live stream. Both were caught by CI rather than locally,
which is an argument for CI being noisier than a developer's machine, not quieter.

**What the plan got wrong.** `ChatModel` and `Persistence` as separate modules never
happened and were not missed — `CaravanUI` holds both, and splitting them now would be
abstraction ahead of a second consumer. The `UserDefaults` stopgap ran five prompts longer
than intended; naming the keys in one enum is what kept the eventual move to one afternoon,
and that trick is worth reusing for anything else deliberately deferred.

## Stage 2, formatting codes — rendering

**Commit:** see PR  **Date:** 2026-08-06

**Shipped:** a new pure module, `IRCFormat` — `IRCFormatting` (the code parser),
`InlineStyle`/`InlineColour`/`RGB`, `MIRCPalette` (both base tables and the fixed 16–98
range), `NickColour`. `CaravanUI` — `Palette` (index → `NSColor`, appearance resolution,
per-index and per-nick overrides), `InlineTraits` and its attribute, the render path in
`LineRenderer`, and a rebuilt `applyFont`/`restyle` in `MessageLogController`. 418 tests
across 42 suites; the authoring half is now its own `PLAN.md` item.

**Decisions:**

- **`IRCFormat` is a pure module, in the Linux job.** The code table and the colour tables
  are tables, and a colour table exercised only through a text view is one nobody
  exercises. Putting it in the Linux manifest makes purity mechanical rather than a
  promise, the same trade `IRCProtocol` already makes. Colours come out as *indices*, not
  colours: which red index 4 is depends on the window, and that is not this module's
  business.
- **Two nick palettes, one per appearance — because one was arithmetically impossible.**
  §6 asks for the palette to be contrast-checked against both backgrounds. Clearing 4.5:1
  against near-white needs relative luminance ≤ 0.183; against near-black, ≥ 0.234. No
  colour satisfies both, and the best any single colour manages is about 4.08:1. So the
  hash picks a *hue* and the appearance picks its lightness: a nick keeps its identity
  across a theme switch and both variants clear AA properly. `oneTableWasImpossible` is
  the test that records why, so nobody collapses the two tables back into one.
- **A sender who named both colours gets both literally.** `^C1,0` is black on white, and
  it stays that way on a dark window because the white is actually drawn behind it.
  Adjusting the foreground there would put light grey on white — destroying the one case
  the sender got unambiguously right. Only a lone foreground is re-tuned, which is exactly
  the case the alternate palette exists for.
- **The light table stays mIRC's literal sixteen.** Yellow on white is unreadable in mIRC
  too; silently darkening it invents a colour the sender did not ask for. Only the dark
  table is ours, so only it has to answer a legibility test.
- **`^D` hex colours are parsed although the item did not ask.** A code left unparsed does
  not disappear — it renders as a control picture and six stray characters mid-sentence.
  Hex is never re-tuned or overridden: there the sender named a value rather than a slot.

**Learned — three ways to silently lose bold, all found by one test:**

- **`AttributedString` → `NSAttributedString` drops custom attributes** unless the scope is
  named: `NSAttributedString(line, including: \.caravan)`. The plain initializer threw away
  every `InlineTraits` on the way into the text storage.
- **Adding `.bold` to a resolved font's descriptor returns a font that is not bold.** The
  descriptor names a specific face and the name beats the added trait.
  `NSFontManager.convert` fails the same way once the font carries a cascade list. Going
  back to the *family* is what actually produces Menlo-Bold — and it keeps the fallback
  cascade, which a bold run needs as much as a plain one.
- **A test that asserts the call returned something asserts nothing.** All three of these
  passed a "did we get a font back" check. Asserting the glyphs were bold is what found
  them.

**Consumed** prompt 10's two carry-forward notes on this item, and prompt 11's: `restyle()`
now rebuilds each run's font from its traits instead of blanket-setting it, so changing the
font size no longer flattens every bold run in the buffer. That is a test now.

**Deferred, and why:** the authoring half — Ctrl+K/B/U/I and the colour strip — is its own
`PLAN.md` item rather than more of this one. Reading and writing share only the code table:
reading is a parser plus a palette, writing is input-field key handling. The rendering half
went first because a client that writes codes it cannot read is the wrong way round. Also
outstanding for that item: the settings-form rows for palette mode and nick colouring, and
a live run — this branch has had none, so `Palette` is still constructed with defaults at
every call site and `auto` does not yet follow the system appearance in the running app.
## Decision — a worktree inventory, and why "removable" is a high bar

**Date:** 2026-08-06

`Scripts/check-worktree.sh` answers "am I loitering in a worktree whose PR has landed?"
and fires only from *inside* one. Nothing answered the question you can only ask from the
repository root: what is lying around in total. Two worktrees had accumulated —
`gui-design` on a long-running design branch, and `item-mirc-formatting-codes` parked
mid-item — and from `main` there was no way to see them, let alone tell which mattered.

`Scripts/worktrees.sh` lists them with a verdict, `--prune` removes the merged ones, and a
second Stop hook blocks at the root when a merged one is still on disk. `make worktrees`
and `make worktrees-prune`.

**Removable means provably merged, never merely tidy.** The two signals are the ones
`check-worktree.sh` already trusts: an upstream that no longer resolves, or a HEAD whose
*tree* matches the base branch. Everything else is listed and left alone. The reason is
that not every worktree here is the assistant's — design conversations live on their own
long-running branches, and a tool that read "not merged yet" as "probably rubbish" would
eventually delete somebody's unfinished thinking. Both current worktrees come back `keep`,
which is the correct answer and the first thing the tool was checked against.

**Rejected: pruning by age, or by branch-name convention.** Age punishes a branch you
thought about for a week; a name convention (`prompt-*` is mine, everything else is not)
breaks the moment a naming rule changes, and it had already changed once this stage.
Merged-ness is a fact about content rather than about labels.

**The ordering bug this also fixes.** `gh pr merge --squash --delete-branch` failed on
both PRs merged today — once with "cannot delete branch 'X' used by worktree", once with
"'main' is already used by worktree" — after the merge had already succeeded remotely,
which reads alarmingly like a failed merge. The branch cannot be deleted while a worktree
holds it, so `--prune` removes the worktree *first* and deletes the branch second. That is
the order to land a PR in from now on: merge, prune, then pull.

**Learned:** `git rev-parse --show-toplevel` answers with whichever worktree you are
standing in, so using it to identify "the main checkout" excludes the wrong entry from the
inventory — the tool listed the real `main` as a stray and hid the worktree it was running
from. The first entry of `git worktree list --porcelain` is the main working tree.

---

## Stage 2, formatting codes — rendering, finished

**Commit:** see PR  **Date:** 2026-08-06

Closes the item the entry above left half-done: the settings-form rows, the `ChatSettings`
persistence, `Palette` reaching the buffers at all, and the live run that entry recorded as
outstanding. The live run found three defects, two of which made most of the item a no-op,
and none of them were visible to a test that stops at the renderer's output.

**Shipped:** `chat.palette` and `chat.colour-nicks` in `ChatSettings`, a Colours section in
the settings form, `ChatSettings.palette` pushed to every `MessageLogController` on creation
and on change, `NickColumn` and its attribute, and appearance-resolving colours in `Palette`.
425 tests.

**Decisions:**

- **An index becomes a colour that resolves itself, and the *window* picks the table.**
  `Palette.colours` now reads both tables and returns an `NSColor(name:dynamicProvider:)`
  when they differ; the mode goes to the scrollback's `NSAppearance`, and AppKit resolves
  each colour against whatever is drawing it. The alternative — resolving to a plain colour
  at render time — cannot repaint the scrollback, and a palette toggle that reaches only the
  next line to arrive fails the acceptance criterion outright. It is also *less* code than
  what it replaced: `systemAppearance` and `MIRCPalette.Appearance.system` are both gone,
  because nothing has to ask the system anything any more. Revisit if a buffer ever needs a
  palette that is not the window's.
- **Pinning the palette pins the window.** Light or Dark sets the scroll view's appearance
  rather than only choosing a table, so the background, the semantic `LineColour` roles and
  the mIRC indices move together. Pinning the table alone would draw the dark palette on a
  white background: less legible than either half of the choice.
- **Colours that agree across both tables stay plain colours.** Hex triples, per-index
  overrides and the whole fixed 16–98 range are one value in both, and a dynamic colour that
  always answers the same thing is a closure call per draw for nothing.
- **The nick toggle needs a different mechanism, because no appearance can express it.**
  Whether a nick is coloured is a claim about the line, not about the window. The renderer
  tags the nick column with a `NickColumn` — the bare nick, and the line's own `LineColour` —
  and `restyle()` rebuilds it: the division `InlineTraits` already uses for fonts. It carries
  the role because by then the storage holds the nick's colour where the line's used to be,
  and turning colouring off has to put something back.
- **`NickColumn` encodes as `role|nick`, split at the first separator.** `|` is legal in a
  nick and illegal in a `LineColour` case name, so that split cannot be fooled by `bob|away`.

**Three defects the live run found, two of them silent:**

- **Naming an attribute scope in the conversion drops every scope not named.** The entry
  above recorded that `NSAttributedString(line)` drops custom attributes and that
  `including: \.caravan` fixes it. It does — and it silently took *AppKit's* attributes with
  it on the way out. No colour, no underline and no link had been reaching the text storage
  at all. The scope now nests `AttributeScopes.AppKitAttributes`. The fix is one line; the
  cost was that every test asserted the renderer's `AttributedString`, which was correct, and
  none asserted the storage, which was empty.
- **A bare `.single` writes SwiftUI's underline, not AppKit's.** `underlineStyle` exists in
  both scopes and the bare form picks `SwiftUI.UnderlineStyle`, which has no
  `NSAttributedString` key and is dropped at the same crossing. Underline and strikethrough
  had never rendered. Fixed by naming the type. This is prompt 10's
  `foregroundColor`-resolves-to-SwiftUI note one scope over, and it will not be the last:
  **when an attribute exists in two scopes the ambiguity resolves silently, and in the
  direction that does nothing.**
- **The nick colour was hashed on the decorated nick.** `@bob` and `bob` hashed differently,
  so the same person changed colour between a channel where he is opped and one where he is
  not — the exact property §6 exists to guarantee. `LineRenderer.undecorated` strips the
  prefix the caller resolved rather than a guessed class of punctuation, because a server
  declares its own `PREFIX`.

`stylingReachesTheTextView` is the test that would have caught the first two, and it asserts
the text storage attribute by attribute rather than the line. The lesson from the entry above
— "a test that asserts the call returned something asserts nothing" — was right, and had not
been applied far enough down the stack.

**Live acceptance, against Libera over TLS,** with a scripted second client in
`##caravan-fmt` sending seven lines of codes. Read back correctly: bold, italic, underline,
strikethrough, monospace (a no-op by rule), reverse, reset, both 16-colour tables, a named
foreground and background pair, the 16–98 range, `^D` hex, and a link. No control character
reached the buffer. Switching Light / Dark / Auto repainted the *existing* lines and the
background together, and Auto followed a live system theme switch.

**Measured by sampling pixels, not by eye** — and that mattered, because reading the
screenshot visually gave the wrong answer twice in a row. Index 8 at `#FEFE4B` against
`#FDF671`, the nick's fuchsia at `#932DAB` against `#E4AFF8`, and scrollback row means of
254 against 30 are what actually settled it. Worth repeating for any later prompt whose
acceptance is "look at it": a screenshot is evidence, but a histogram of it is the reading.

Turning nick colouring off recoloured lines already on screen, and back on restored them.
Both settings round-tripped through `caravan.conf`.

**Deferred:** per-index and per-nick overrides have no UI. `Palette` carries both and both
are tested, but the form offers neither — they belong with stage 3's Colors dialog, where a
99-swatch grid can be built properly rather than bolted onto a settings list. Recorded on
that `PLAN.md` item.

---

## Stage 2, prompt 2 — the input field grows up

**Commit:** see PR  **Date:** 2026-08-06

Authoring the codes prompt 1 taught the buffer to read, and completing what you are typing.
Both items in one prompt because both are `InputTextView`, and two prompts would have
touched the same forty lines twice. 450 tests.

**Shipped:** `TabCompletion` and `CompletionSources`, `InputStyling`, `ColourStrip`,
`CommandParser.knownCommands`, a `range` on every parsed run, and the key handling that
joins them up.

**Decisions:**

- **The chords are read in `keyDown`, not `doCommand(by:)` — the prompt's plan was wrong
  about this.** It said "Tab arrives there as `insertTab:`, and so do the control-key
  chords". Tab does; the chords do not usefully. **Ctrl+I *is* Tab** — the same character,
  arriving as the same selector — while Ctrl+B and Ctrl+K arrive as `moveBackward:` and
  `deleteToEndOfParagraph:`, the Emacs bindings AppKit ships. By `doCommand` the letter is
  gone and only `keyDown` still has `charactersIgnoringModifiers`. Taking those bindings is
  the deliberate trade: in an IRC input box, Ctrl+B meaning bold is the older muscle memory.
- **Ctrl+O and Ctrl+R ship too**, though the prompt named only four. Without a reset you
  cannot stop a code, and reverse has no other way in; they are the same table.
- **The codes stay visible in the box, as dim `^B` markers.** mIRC hides them. An invisible
  control character in an *editable* box gives a caret that moves without visible cause and
  a Backspace that appears to delete nothing — the box is the one place the raw text has to
  be honest, because it is the thing being sent. `showsControlCharacters` draws them, so
  the marker is AppKit's own rather than a substitution that would change what goes out.
- **`FormattedText.Run` gained a `range`, and that is why the input box needs no second
  parser.** The buffer strips the codes and styles what is left; the box must keep every
  character and style the stretches *between* the codes. One parse answers both, with the
  codes as the gaps between consecutive ranges. `InputStyling` is the opposite operation to
  `LineRenderer`'s and is separate code for that reason, not for want of reuse.
- **The colour strip is sixteen swatches, not ninety-nine**, and its colours come from
  `Palette` rather than a second table. The extended range is typed as digits, which is how
  it is reached in mIRC. A 99-swatch grid hanging off an input box is a colour dialog, and
  that is stage 3's.
- **A picked colour is written as two digits.** `^C4` followed by a message beginning with
  a digit reads as index 42 on the receiving client. Zero-padding costs one character.
- **The suffix is configurable, and stored with `_` for a space.** The prompt asked for a
  configurable suffix and it would have been easy to ship only the rule. `caravan.conf`
  cannot hold a value that begins or ends with a space — whitespace around a value is not
  significant, which is a deliberate property of the format rather than a limitation — and
  `": "` is exactly such a value. `_` stands for a space on the way in and out. The
  alternative was a quoting scheme, which is a much larger change to a format whose paths
  are public API, for one setting.
- **`CommandParser.knownCommands` lives beside the switch it lists.** The input box must not
  keep a second copy of the command table. It is still hand-kept — Swift cannot enumerate a
  `switch` — so `everyKnownCommandParses` checks the half that is checkable: nothing listed
  may fall through to the passthrough. A case added and not listed is only catchable by
  reading, which is why they are adjacent.

**Found by its own tests, before any of it ran:** completing `#swift` at the start of a line
produced `#swift: `, addressing a channel as though it were a person. The suffix and the
candidate list were being decided separately and had drifted apart; both now come from one
`Kind` decided once. Two tests would have had to be wrong together to miss it.

**Found by the live run, twice.** The colour strip **did not go away when you typed the
digits** —
which is the case it exists to support. `.transient` closes a popover when the user
interacts *outside* it, and a keystroke aimed at the box behind it does not count, so the
strip sat there through `04red` and the next Ctrl+K merely closed it. `didChangeText()` now
dismisses it: every edit puts it away, including the `^C` that opened it, which is inserted
before the strip is shown and so cannot dismiss its own strip.

And the suffix setting's form rows were **unusable on first draw**: a `TextField` inside a
`LabeledContent` draws its own placeholder as a second label, and in a 70pt box that label
wrapped one word per line — a five-line-tall row with a sliver of field beside it. Every
test passed; nothing but looking at it would have found it. `labelsHidden()` fixes it, and
the fields are bordered where the form's others are not, because a suffix is often a single
space and an unbordered field holding one looks like no field at all.

**Not covered by a test, and deliberately:** that the strip presents at all. `NSPopover`
never reports `isShown` in a headless test bundle, so the assertion passes or fails on the
test environment rather than on the code. A test written for it was deleted rather than
left flaky; the strip is checked live, and this entry is the record that it was.

**Learned — the wrong-binary lesson has a third form.** Prompts 9 and 10 both recorded
`DerivedData` being keyed on the project path. This time the path was right and the
*instance* was wrong: `⌘Q` through System Events silently failed, three copies of Caravan
were running, and `tell process "Caravan"` addressed whichever one it found. Two live checks
were made against a binary two builds old, and both "reproduced" a defect that was already
fixed. `ps aux | rg Caravan.app` before trusting a live check, and `pkill -f` rather than
`⌘Q` to end one.

**Live acceptance, against Libera over TLS,** in `##caravan-input` with a scripted listener
as the second party. Composed the prompt's line — a Tab-completed nick, `^B`bold`^B`, a
`^C04` colour and `^O` — and watched the box draw it while typing: **loud** in bold, `red`
in red, the codes as dim markers. Sent it; the listener heard exactly
`caravanin2: \x02loud\x02 and \x0304red\x0f done`, and the buffer echoed it looking the way
it had looked while being typed. Also live: Tab completion of a nick with `: ` at line
start, `/j` → `/j ` → `/join ` cycling through the aliases, `##ca` completing mid-sentence
with a space rather than a colon, and the strip opening, dismissing on the digits, reopening,
and inserting `04` from a clicked swatch. The suffix setting was changed to `, ` in the form,
checked in `caravan.conf` as `,_`, and then watched completing `carav` to `caravanin1, `.
