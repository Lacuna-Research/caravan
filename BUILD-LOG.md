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

## Stage 2, prompt 3 — capabilities and authentication

**Commit:** see PR  **Date:** 2026-08-06

IRCv3 capability negotiation, SASL, NickServ, the Keychain, and the TLS trust decision
stage 1 deferred. One prompt because SASL *is* a capability: it rides on CAP LS/REQ/END,
and splitting them means building the negotiation state machine twice. 549 tests.

**Shipped:** `ClientCapability`/`NegotiatedCapabilities`/`CapabilityCommand`, `SASLExchange`
and `SASLWire`, `AuthenticationMethod`, `StandardReply`, the phase machine in `IRCSession`,
`TLSTrust`/`TLSCredentials`/`TLSClientIdentity`, `CredentialStore`/`Keychain`, `KnownHosts`,
`ClientCertificate`, `TrustSheet`, and eleven new `IRCEvent` cases.

**Decisions:**

- **A rejected credential ends the attempt and does not reconnect.** IRCv3 allows a client
  to carry on unauthenticated after a 904, and several clients do. Against Libera that
  means silently connecting with your IP exposed and no access to `+r` channels — the
  client having decided, on your behalf, that authentication was optional. `.authentication
  Failed` is its own `DisconnectReason` and is never retried: a wrong password does not
  become right on the second attempt, and a client that loops on one is how an account gets
  locked and an IP gets throttled. Revisit if a network turns out to send 904 transiently.
- **NickServ is the fallback for a server that *cannot* do SASL, never for a credential the
  server refused.** Those are different failures wearing the same word. `Authentication
  Method.nickServFallback` is consulted only when `sasl` was never enabled, and the client
  says out loud that it is about to identify the worse way — the password crosses a
  registered but unauthenticated connection, and anything arriving before it happens as a
  stranger.
- **`echo-message` suppresses the *local* echo, not the server's copy.** Either would give
  "exactly once". The server's is the better line: it carries the `server-time` the message
  was actually accepted at, its `msgid`, and the ordering everyone else sees. One condition
  in `ConnectionViewModel.send`, which is what `LineKind.isSelfEcho` was built for in stage
  1 — a filter on the way out rather than recognising our own words coming back.
- **`server-time` reaches the renderer as `IRCTags` on `IRCEvent.message`, not as a `Date`.**
  `IRCSession` has no Foundation dependency and no clock; parsing a timestamp it does not
  itself use would be the wrong layer. Carrying the whole tag section rather than one field
  also hands prompt 12 the `msgid` it needs to de-duplicate a replayed log. Only `.message`
  carries them — prompt 4 replays joins and topics and will want the same for those.
- **`allowSelfSigned` is gone, replaced by `TLSTrust.trustOnFirstUse`.** The flag accepted
  an unvalidated certificate silently on the promise that a UI would eventually ask; nothing
  enforced the promise. Trust is now a *decision*: system validation first, and where it
  fails, `TLSCredentials.trustEvaluator` is asked across a suspension while the handshake
  waits. **With no evaluator the handshake fails.** That is strictly less permissive than
  what it replaced and strictly more permissive than refusing outright, which is why it is
  now the default for every TLS connection rather than an option.
- **`known_hosts` is a plain-text file, not a Keychain item.** A fingerprint is public
  information, so it goes in `$XDG_DATA_HOME/caravan/known_hosts` in SSH's format —
  deleting a line has to be how you forget a decision, and that means a file a person can
  open.
- **`CredentialStore` is a protocol with one production implementation.** Not speculative:
  the first run of the suite after the Keychain landed wrote `s3cr3t-not-real` into the
  developer's login keychain, and "remember to delete it afterwards" is not a mechanism.
  `ConfigFile` takes a URL for the same reason. `EphemeralCredentialStore` is what tests and
  previews get.
- **`labeled-response` is negotiated without being exercised.** It is inert without an
  outbound `label` tag, and the two things that want one — `chathistory` in prompt 4,
  command replies in prompt 8 — do not exist yet. One token now against a rewrite of the
  negotiation later. Recorded because it is exactly the kind of thing that looks like an
  oversight when read cold.
- **Caravan does not generate or import client certificates.** `ClientCertificate.identity
  (labelled:)` looks one up by its Keychain label and nothing more. Keychain Access and
  `openssl` already do the rest well, and a client growing a half-version of them would be a
  worse place to keep a private key.

**Surprises:**

- **`CAP LS` has to go out before `PASS`, not after `USER`.** The obvious order — keep
  registration as it was, append the CAP exchange — races a server that answers `CAP LS`
  immediately. Registration is held open until `CAP END` either way, so the first line on
  the wire is now `CAP LS 302`.
- **The whole failure mode of this prompt is a *hang*, not an error.** Every path that loses
  track of `CapabilityPhase` — a `NAK`, a server that ignores `CAP` entirely, a `sasl`
  requested for a mechanism the server does not offer — ends with no `CAP END` and a
  connection that sits there until the 30-second connect deadline. Four of the ten tests in
  `AuthenticationTests` exist only to pin that, including the one where a server that never
  answers `CAP LS` must still register and must *not* then emit a stray `CAP END`.
- **`sec_protocol_verify_complete_t` cannot cross into a `Task` without help.** It is an
  Objective-C block, not `Sendable`, and answering the trust question asynchronously is the
  entire point. `VerifyCompletion` is an `@unchecked Sendable` box with the justification at
  the conformance: Network.framework documents the block as callable once from any queue.
  `SecTrust` is summarised into a `TLSCertificate` synchronously, before the hop.

**Measured, against Libera over TLS.** `CAP LS 302` comes back multiline; `multi-prefix`,
`server-time`, `echo-message` and `extended-join` all negotiate; `sasl` is offered with
`PLAIN,EXTERNAL,SCRAM-SHA-256`. A SASL PLAIN attempt with a nonexistent account produced
`904`, ended the attempt with `.authenticationFailed`, never reached `.connected`, and left
`AUTHENTICATE <redacted>` in the trace with `AUTHENTICATE PLAIN` intact beside it. Joining
`##caravan-caps` and sending a line produced **exactly one** copy in the buffer, rendered
`<@caravan143247> ...` — with the prefix, because we are opped in a channel we just created,
which is what caught an over-strict assertion in the live test rather than a bug.

**SCRAM-SHA-256 is checked against RFC 7677's published exchange**, not against itself. A
client and a server that make the same mistake agree with each other perfectly; the vector
is the only thing that says the arithmetic is right. `Hi` is PBKDF2-HMAC-SHA-256 written out
in fifteen lines rather than reached for in CommonCrypto — the derived key is exactly one
hash long, so the multi-block form is not needed and the mechanism stays inside CryptoKit.
The server signature is compared in constant time; the timing of `==` over `Data` is a
function of how many leading bytes matched.

**The self-signed TLS path has a fixture, and it earned one.** `SelfSignedTLSTests` runs
against `openssl s_server` with a throwaway certificate (the invocation is in the suite's
doc comment) and is the only thing that executes the *asynchronous* half of the verify
block — the suspension the handshake waits across. It confirmed all three answers: asked
and accepted, asked and refused (handshake fails), and no evaluator at all (handshake
fails, rather than the silent accept the old flag did). With
`CARAVAN_SELF_SIGNED_FINGERPRINT` set it also pins that the digest the user would be shown
is the server's own, which is the one way a trust prompt can be actively harmful.

**Not done, and why: the GUI acceptance run.** The machine was locked for the whole session
— `screencapture` returned black and `System Events` reported zero windows for a running
Caravan — so the three things only a screen can confirm were not confirmed: that the Connect
sheet's Authentication section lays out (a `Picker` plus conditional rows, and prompt 2's
build log records a form row that every test passed and no eye had seen), that `TrustSheet`
presents and is readable, and that the two password fields arrive pre-filled from the
Keychain. Everything below the pixels was checked headlessly instead, including against a
real ircd and a real self-signed handshake. **This is the outstanding item for this prompt**
and it is on the PR.

## Stage 2, prompt 3 — laying the sheets out without a screen

**Commit:** see PR  **Date:** 2026-08-06

A follow-up to the entry above, and a partial answer to the item it left outstanding.

With the machine locked, the honest options were "ship two unlooked-at sheets" or "find out
what a machine *can* check about them". `SheetLayoutTests` hosts `ConnectSheet`,
`AuthenticationSection` and `TrustSheet` in an `NSHostingView` offscreen, lays them out at
the size the app presents them, and measures. It cannot say whether a label reads well. It
can say whether a row collapsed or exploded, which is precisely the defect prompt 2 shipped:
a `TextField` inside a `LabeledContent` drew its own placeholder as a second label, wrapped
one word per line, and produced a five-line row with a sliver of field beside it.

**Measured, so the bound is not a guess:** a `Form` row is ~37pt. The Authentication section
is 104pt for `.none`, 178pt for the three methods with an account and a password, and 215pt
for `.saslExternal`, which adds the certificate field and its explanatory paragraph. The
ceiling is 300pt — two rows of headroom for metric drift between OS versions, and still well
under the ~355pt that turning one row into five would produce.

**`AuthenticationSection` became its own view to make this possible**, and it is a better
shape anyway. `ConnectSheet` fills itself in `onAppear`, which does not fire offscreen, so a
test hosting the whole sheet only ever measures the `.none` case — the conditional rows,
which are the part at risk, would never render. A view taking a `Binding` can be laid out
once per method.

**Still not checked, and the entry above still stands:** that the sheets *read* well, that
the trust sheet's red-for-a-changed-certificate lands, and that the password fields visibly
arrive pre-filled. Measuring is not looking.

## Stage 2, prompt 3 — refusing a certificate has to mean refusing it

**Commit:** see PR  **Date:** 2026-08-06

A defect the GUI acceptance run found the moment it became possible to do one, in the code
merged an hour earlier. The entry above records that the run was outstanding; this is what
it caught.

**What happened.** Declining a certificate in `TrustSheet` produced this:

    *** Disconnected: receive failed: -9808: bad certificate format
    *** Reconnecting (attempt 1) in 2.4s
    *** Connecting...

and the trust sheet reappeared. Two things wrong, one of them badly.

- **The client reconnected from a decision.** `complete(false)` fails the TLS handshake
  through the ordinary error path, so the session saw a transient-looking transport failure
  and did what it does with those. The dialog would come back every couple of seconds until
  the backoff ceiling, and then keep coming back. A prompt that will not accept "no" is
  worse than no prompt, because it trains people to click the other button.
- **The reason was Security.framework's, not ours.** `-9808: bad certificate format` reads
  as a broken server. Nothing said the client had been told to refuse it.

**The fix.** `TransportError.trustRefused` and `DisconnectReason.trustRefused`.
`IRCConnection` latches a `RefusalFlag` when the verify block answers `false` — before
answering, since the handshake failure races back the instant `complete(false)` returns —
and `finish(_:)` substitutes the reason on the way out. `IRCSession` treats
`.failed(.trustRefused)` like a deliberate disconnect: `allowingReconnect: false`, the same
as `.authenticationFailed`. Both are answers, and asking again is not how you get a
different one.

**Why no test caught it.** `SelfSignedTLSTests` asserted the handshake *failed*, which was
true and remained true. What it did not ask was what the layer above then did — and the
layer above is where the whole behaviour lived. The transport test now asserts on
`.failed(.trustRefused)` specifically rather than on "some failure", and
`LiveTrustRefusalTests` drives a whole `IRCSession` at the refusal and asserts no
`.reconnecting` state is ever emitted. That second one is the test that would have caught
this, and it did not exist because the transport suite looked like enough coverage.

**The general lesson, and it is the third time this project has learned it:** a test that
stops at the seam it is about will miss anything the next layer does with the result. Stage
1 shipped three defects a live run caught in a minute; this is a fourth, and the only reason
it took an hour rather than a stage is that the run happened as soon as the screen was
available.

**Verified live, in the app:** the fingerprint shown matches `openssl x509 -fingerprint
-sha256` exactly, for a fresh certificate and again for a rotated one; the changed-
certificate case draws in red with the previous fingerprint beside the new one; accepting
writes `known_hosts`; refusing leaves it untouched, ends the attempt, and now stays ended.

## Stage 2, prompt 4 — multi-network, and the bouncer

**Commit:** see PR  **Date:** 2026-08-06

Two networks at once, and one bouncer pretending to be several. Together because bouncer
mode *is* `bouncer-networks`: writing multi-network without it means writing the sidebar
model twice. 570 tests.

**Shipped:** `AppModel.connections` in place of `connection`, `BouncerNetwork` and
`BouncerReply`, `BOUNCER BIND`/`LISTNETWORKS` in the negotiation state machine,
`CHATHISTORY LATEST` on join, the `<user>/<network>` fallback, and per-connection expansion.

**The design decision the whole prompt turns on: `BOUNCER BIND` goes on the connection being
registered, so *both modes are one connection per network.*** The prompt describes bouncer
mode as "a single connection to soju where `soju.im/bouncer-networks` enumerates the
upstream networks", which is half right — the enumerating connection is one, but the
extension requires a bind before registration completes, and a bound connection is talking
to an upstream network rather than to the bouncer. So a bouncer is **one control connection
plus one per network**, and a direct setup is one per network. The tree is a flat list of
networks in both cases, and "the UI must not care which is in play" falls out rather than
having to be engineered. Read the spec rather than trusting memory; the memory was wrong.

**Decisions:**

- **Connecting adds a network rather than replacing one.** It replaced because there could
  only be one. "Connect" now means what the Connect sheet and `/server` have always looked
  like they meant. Same host, same port *and same ident* selects what is already open
  instead of growing a duplicate row — the ident is in that test because `alice/libera` and
  `alice/oftc` are the same host and are emphatically not the same network.
- **A bouncer's networks are siblings of direct ones, not children of the bouncer.** Nesting
  would make the tree two levels deep for a bouncer and one for a direct connection, which
  is precisely the UI caring which mode is in play.
- **The bouncer keeps a row of its own.** So the tree is *not* byte-identical between the
  two modes: a bouncer contributes one extra row. It earns it — `BouncerServ` is reachable
  there and bouncer-level failures have to land somewhere — and the part the prompt cares
  about, the networks and their channels, is identical. Recorded as a deviation rather than
  quietly satisfied.
- **A bind that cannot happen fails the attempt.** A bound connection whose server turns out
  not to support the capability would otherwise register against the bouncer itself and show
  the wrong network's traffic under this network's name, silently, which is the worst
  possible failure for this feature.
- **The whole network list is re-emitted on every change, never a delta.** `IRCEvent
  .bouncerNetworks` carries all of them, and `AppModel.reconcileBouncerNetworks` reconciles.
  Applying a stream of edits to a list of open buffers is much easier to get wrong.
- **Discovering a network never steals the selection.** They arrive seconds after connecting
  and several at once; yanking the user into the last to arrive would be its own hostility.
- **Closing a bouncer closes the networks behind it.** They are reached *through* it, and a
  row that could never reconnect is a lie the tree tells.
- **`CHATHISTORY LATEST` fires on our own `JOIN` only.** A busy channel would otherwise
  produce one request per arrival. A limit of zero turns backfill off, and means "ask for
  nothing" rather than "ask for zero lines".
- **A network takes its name from `ISUPPORT`'s `NETWORK=`**, and a name passed in at
  construction outranks it — the bouncer's word for an upstream network beats that
  network's own, because the bouncer is the thing that knows there are several behind one
  host.

**Surprises:**

- **`ScriptedIRCServer` could only hold one connection at a time**, and silently cancelled
  the previous one on accept. Every test until now used one connection, so nothing had
  noticed. A bouncer test has a control connection *and* a bound one, and the symptom was a
  notification arriving at the wrong session — which read as a product bug for a while. It
  now keeps a list, broadcasts `send`, and gives each connection **its own `LineFramer`**:
  two clients' bytes interleave on the way in, and one shared framer splices a line from
  each into nonsense.
- **A `switch` case that could never match.** `adoptNetworkName` was added as
  `case .numeric(5, let parameters)` *after* the general `case .numeric(let code, ...)`, so
  it never ran and the network was never renamed. Swift warns about many things; an
  unreachable enum-pattern case with a payload constraint is not one of them.

**Carry-forward consumed, and one only half:** the expansion state moved off
`AppModel.isNetworkExpanded` onto `ConnectionViewModel.isExpanded`, and the two capabilities
were added as the notes asked. The note about **widening `IRCTags` beyond `IRCEvent.message`
is deliberately not done** — soju's `chathistory` replays messages, which already carry
their tags, so the general envelope would be built for events this bouncer does not send.
The note moves to prompt 12, which owns de-duplication and is where a replayed `JOIN` would
first actually matter.

**Verified live, against Libera and OFTC at once:** both connected under one `AppModel`,
each taking its own name from its own `ISUPPORT` (`Libera.Chat` and `OFTC`), with
independent capabilities and independent selection. That is the first half of the prompt's
acceptance and it is now a test.

**Not done: the bouncer half of the acceptance, and the GUI.** There is no soju to point at
— `PLAN.md`'s testing strategy has wanted a local one since stage 1 and this is the prompt
that finally needs it — so bouncer mode is proven against a scripted server that speaks the
extension, and against the spec, but not against soju itself. And the machine was locked
again, so the tree was not looked at. Both are on the PR.

## Stage 2, prompt 4 — what the live run found

**Commit:** see PR  **Date:** 2026-08-06

The screen came back mid-PR, so the tree got looked at after all. It found two things, one
of them the whole feature.

**There was no way to open a second network.** The toolbar alternated between "Connect…"
and "Disconnect" — correct when there could be one connection, since "connect" then meant
"connect *this*". This prompt changed it to mean "open another network", and hiding it while
one is connected left multi-network unreachable from the UI: the empty-state button is gone
once a network exists, and the toolbar showed only Disconnect. Both buttons now, with
Disconnect disabled rather than absent. Every test passed; nothing but looking would have
found it, which is the third time this project has written that sentence.

**A stale reconcile could resurrect a removed network.** `reconcileBouncerNetworks` read the
network list, then suspended in `open()` to bring a connection up. A `BOUNCER NETWORK <id> *`
arriving during that suspension was reconciled against a list that was already stale, and
the removed network came back. It is now serialized per bouncer and re-runs while the list
keeps moving. This one *did* show up as a test failure — but intermittently, and only after
the toolbar rebuild happened to change the timing, which is the kind of failure it is very
tempting to re-run and call a flake.

**Verified live, in the app, against Libera and OFTC at once.** Both rows named from their
own `ISUPPORT` — `Libera.Chat` and `OFTC`, not their hostnames. A channel joined on each,
deliberately near-identically named (`##caravan-multi` and `#caravan-multi`), and a line
sent in each: both landed in the right buffer, each window's subtitle naming its network.
Collapsing Libera left OFTC expanded, which is stage 1 prompt 8's carry-forward doing what
it was asked for.

**Still outstanding: soju.** The bouncer half of the acceptance has nothing to run against.

## Retrospective — the prompt system, four prompts into stage 2

**Commit:** see PR  **Date:** 2026-08-06

Written at the end of a session that ran prompts 3 and 4 back to back, while the detail was
still recoverable. Stage 1's retrospective is above; this one is about the *process* rather
than the code, and it is deliberately more critical than complimentary, because the parts
that work need no attention.

### What is carrying the weight

**`check-docs.sh` is the best thing in the setup.** Across both prompts it caught the status
line, the README badge, the README table row count and stale carry-forwards — every time,
without anyone having to remember. `CLAUDE.md`'s "make it mechanical rather than writing it
more emphatically" is the principle the whole discipline rests on, and it held under two
large prompts and a five-hour CI outage.

**Carry-forward notes earned their keep twice in one day.** Prompt 3's note told prompt 4
exactly where to start — two cases in `ClientCapability`, machinery already generic — and
stage 1 prompt 8's note about `AppModel.isNetworkExpanded` was written a long way back and
was still precisely right when it came due. The rule that makes them work is "name the seam,
not the topic". Every note that named a file and a symbol was actionable on sight.

**Just-in-time prompt detail was vindicated hard.** Prompt 4's brief described bouncer mode
as "a single connection to soju where `soju.im/bouncer-networks` enumerates the upstream
networks". That is *wrong*: `BOUNCER BIND` must be sent on the connection being registered,
so a bouncer is a control connection plus one per network. Reading the spec caught it in
twenty minutes. Had prompts 5–17 been written out in full detail at the start of the stage,
that error would have been followed rather than caught — which is exactly the failure the
just-in-time rule exists to prevent, observed in the wild rather than argued about.

### Where it needs work

**The carry-forward check rewards deletion, not consumption.** It verifies only that no
`Carry-forward` heading survives on a prompt numbered at or below the completed count —
which is satisfied by deleting the block unread. Prompt 4 consumed two of its three notes,
declined the third deliberately (the `IRCTags` widening, since soju replays only messages)
and moved it to prompt 12; that was recorded, but nothing required it. A cheap fix: require
the `BUILD-LOG.md` entry for a prompt that had carry-forwards to mention them, which is one
more `grep` in the script. Recorded here rather than made mechanical in the same breath,
which is itself an instance of the problem.

**"Run it live" and "a green PR is authorisation to land it" are in tension when the live
run cannot happen.** The machine was locked for most of this session. The improvised
substitutes were good — headless live tests against Libera and against a real self-signed
handshake, and hosting the SwiftUI sheets in an offscreen `NSHostingView` to measure them —
but nothing in the finishing checklist asked for a substitute or required naming one. The
cost was concrete and immediate: **the trust-refusal reconnect loop shipped to `main` and
was found an hour later**, by the acceptance run that had been deferred. The checklist wants
an explicit branch: if step 5 cannot happen, say so in the `Status:` line, name the
substitute, and treat the prompt as provisionally done.

**Prompts 3 and 4 were each arguably two prompts.** Prompt 3 was CAP negotiation, three SASL
mechanisms, NickServ, the Keychain, TLS trust-on-first-use, `echo-message`, `server-time` and
eleven new `IRCEvent` cases. Prompt 4 was a multi-network model refactor plus the bouncer
extension plus `chathistory`. Both landed in a session, but near the limit, and the queue's
own escape hatch — "a large item may span two" — went unused. Worth a sizing pass over the
remaining thirteen before starting them.

**The `Status:` line is drifting into a paragraph.** Prompts 3 and 4 both now carry an
outstanding-items narrative in a field `check-docs.sh` parses for a completion count. The
information is right and belongs somewhere; that field was not designed to hold it.

### The thing worth remembering

**Every defect that mattered today came from looking, not from testing.** 571 tests passed
while multi-network had no way to open a second network from the toolbar — the feature's own
front door, missing, with full green CI. The trust-refusal loop likewise. And the offscreen
layout test written as a *poor substitute* for looking turned out to be the most durable
artifact of the session, because it encodes prompt 2's defect class permanently: a form row
that collapses or explodes is now caught by a number rather than by an eye that happens to
be available.

The suggestion that follows: make "what did an eye actually check?" a named line in the
finishing checklist, separate from the test count. A prompt that answers "nothing" is not
wrong, but it should have to say so.

## Stage 2, prompt 4 — a red main, and a harness that lied

**Commit:** see PR  **Date:** 2026-08-06

`main`'s post-merge run for prompt 4 failed — the first CI job in this repo to actually
execute after the Actions outage, and it failed in 1m19s rather than timing out, so it was
real. `a network the bouncer drops loses its row`, the very test whose stale-reconcile race
had been fixed hours earlier.

**It reproduced locally at about one run in four, and only under full-suite load.** In
isolation it passed indefinitely. That is the shape of a test that depends on timing between
two connections, and it is why five green single-test runs and three green full-suite runs
before merging proved nothing.

**Instrumenting beat reasoning, and by a wide margin.** Two rounds of speculation about the
reconcile serialisation produced nothing; one `print` of the state at failure produced the
answer immediately:

    rows=["ExampleNet/-", "Libera/1"] controlNetworks=["1"] conns=3
    lines=[... "BOUNCER LISTNETWORKS" ... "BOUNCER BIND 1" ... "BOUNCER LISTNETWORKS"
           ... "BOUNCER BIND 1" ... "BOUNCER LISTNETWORKS"]

Three connections where there should be two, `BOUNCER BIND 1` twice, and `LISTNETWORKS`
three times.

**The cause was in `ScriptedIRCServer`, not in the client.** Multi-connection support was
added to it in this prompt, and `send(_:)` was made to broadcast — correct for a line the
server *volunteers*, which is what a `BOUNCER NETWORK` notification is, and wrong for a
scripted *reply*. So a welcome burst triggered by the bound connection's `CAP END` was
delivered to the control connection as well. The control saw a second `001`, re-ran
`handleWelcome`, re-sent `BOUNCER LISTNETWORKS`, and re-added the network the test had just
removed. Every symptom pointed at the product; nothing was wrong with the product.

**The fix is the distinction the harness had lost:** a scripted reply goes to whoever asked
(`send(_:to:)`), an unprompted line goes to everyone (`send(_:)`). Both halves are now pinned
by `ScriptedServerTests`, and the pinning was *verified by reintroducing the bug* — with
replies broadcast again, the new test fails on exactly the assertion it exists for. A
regression test nobody has watched fail is a regression test nobody knows works.

**What this says about the process**, on the same day the retrospective above argued that
mechanical checks are what carry the discipline: CI caught this and local runs did not,
because CI is a different machine under different load. Repeating a suspect test locally is
weak evidence. The stronger habit, for anything with two connections or two tasks in it, is
to run the *whole* suite several times — the load is the variable — and to treat "passed in
isolation" as almost no evidence at all.

**Also recorded: the earlier fix was not wrong, merely insufficient.** The reconcile
serialisation added hours earlier is still needed and still correct; it closed a genuine race
between an `open()` suspension and an incoming removal. It simply was not the cause of this
failure, and the temptation to believe a recent fix must be the culprit cost two rounds of
theorising before the `print`.
## Decision — command-line control, and why it sits next to scripting

**Commit:** see PR  **Date:** 2026-08-06

A `caravan` CLI driving the running app was proposed, discussed and put in `PLAN.md` as
stage 3 item 34a. No code; this records the choices while the reasoning is fresh, because
several of them are the kind that cannot be revisited once anyone has scripted against
them.

**It goes beside scripting because it is the same surface.** Item 34 already promises "a
capability-scoped `irc` object: send, join, part, query client state", which is the set a
CLI needs. Building them separately produces two vocabularies and two sets of bugs, so the
deliverable is one control API with three front ends — `CommandParser`, the JS object, and
the socket. Whichever of the two is built first pays for the extraction.

**Transport: a Unix-domain socket, over three alternatives.**

- *XPC* is the macOS-native answer and was rejected: it needs code-signing and app-group
  setup, it is awkward to reach from a shell script, and its whole advantage is sandbox
  traversal — which does not apply, because the app is deliberately unsandboxed for DCC and
  identd.
- *Apple Events with an `.sdef`* would give Shortcuts support free, but the format is
  painful, the model is poor for streaming, and it is a third front end rather than a
  transport. Reachable later *through* the socket if wanted.
- *HTTP on localhost* was rejected as a listening TCP port, which is real attack surface
  needing an auth scheme, to solve a problem the filesystem already solves with `0600`.

**The socket lives in `$XDG_CACHE_HOME`, not a new `$XDG_STATE_HOME`.** `XDG_RUNTIME_DIR`
is the correct XDG answer and macOS does not set it. Introducing a fourth directory would
mean editing `CLAUDE.md`'s "Where things live", and that file is at 99 lines against a hard
cap of 100 that is explicitly not to be raised. A socket is recreated on launch, so it is
honestly cache-shaped, and the `zap` stanza in item 46 already removes that directory.

**Addressing is `network/target`, parsed at the first `/`.** `#swift@libera` was the
alternative and reads more like IRC, but `/` sorts and reads like a path, and it matches
`<user>/<network>`, which the codebase already uses for the bouncer fallback. The rule that
matters more than the punctuation: **the network may be omitted only when exactly one is
open, and is never guessed.** `#music` on two networks are different rooms is what the
whole tree is built on, and a CLI that guesses sends a stranger your message. The proposal
that started this discussion had `message send #channel` and `whois network user` — the
network implicit in one and first-positional in the other, which is the sort of thing that
sets hard.

**`caravan raw` ships from the start.** It is one passthrough to a `CommandAction` that has
existed since stage 1, it matches "the protocol is not hidden", and an escape hatch takes
the pressure off rushing half-considered verbs in to unblock somebody — which is itself a
compatibility argument.

**Two rules written down now because they are load-bearing later:** JSON is the contract
and the human format is explicitly unstable, or the first person to `awk` it freezes it
forever; and the socket never reads secrets back, because stage 2 prompt 3 put every
credential in the Keychain and a control socket that hands them out would quietly undo it.

**Left open, in `PLAN.md`:** what a network's stable user-facing name is — settled in stage
2's Dashboard prompt, since that is where the server list is born and renaming an
identifier afterwards has no good migration — and whether the socket is always on or
opt-in.
## Decision — a website, in `docs/`, built like the client

**Commit:** see PR  **Date:** 2026-08-06

GitHub Actions went down mid-morning, which made it a good moment for work that does not
need CI to iterate: a project website. It lives at `docs/index.html` + `docs/style.css`,
and the decisions were all the same decision:

- **Static HTML and CSS, no JavaScript, no build step, no framework.** Jekyll, Hugo and
  friends were rejected without much agonising — a site that needs a toolchain to say
  "zero dependencies" is a joke at its own expense. Two files, viewable with `open
  docs/index.html`, servable by anything.
- **`docs/` on `main`, not a `gh-pages` branch.** GitHub Pages serves `/docs` from the
  default branch with no extra workflow, and an orphan branch is a second thing to keep
  in sync and a permanent exception to the worktree/branch housekeeping rules.
- **The palette is `MIRCPalette.swift`'s, verbatim.** The site's dark appearance uses the
  dark table (accent `#3CC8C8` is index 10, orange highlights are index 7), light uses
  mIRC's own light table, and the strip under the hero is the full 0–98 range in order.
  Same rule as the client: two palettes, not one inverted.
- **The window is CSS and labelled a mockup**, like the README's ASCII art — no
  screenshot was faked and none was taken; the machine's display was not available to
  drive the real app, and the README's honesty about this reads well anyway.
- **The condensed build-log timeline is sixteen entries** picked from this log —
  decisions with rejected alternatives, live-run surprises, milestones. It is a
  hand-written digest and says so, linking here for the full record.

**What will drift:** the page states stage 2 progress (3/17, and a progress-meter width)
that `check-docs.sh` does not check, exactly the class of stale-badge problem rule 5
exists for. Raised in `PLAN.md`'s Still open list rather than fixed now.

**Verified** with headless Chrome screenshots: both appearances, full page height, and a
phone-width run — which found a fake defect first: Chrome will not lay out narrower than
485px however small `--window-size` asks to be, so a "390px" screenshot is a 485px layout
cropped, and everything looks clipped. A probe script measuring
`document.documentElement.clientWidth` settled it; the CSS was never wrong.

## Note — the website's progress numbers went stale before it merged

**Commit:** see PR  **Date:** 2026-08-06

The website's own decision entry above predicted this: "the page states stage 2 progress
(3/17, and a progress-meter width) that `check-docs.sh` does not check, exactly the class
of stale-badge problem rule 5 exists for."

It came true between the branch being written and the branch being merged. Prompt 4 landed
in the interval, so `docs/index.html` was carrying `3/17` and a `17.6%` meter against a
`main` that says 4/17. Corrected to `4/17` and `23.5%` on the way in, along with the
"next:" list, which still named multi-network as upcoming, and a timeline entry for it —
the site leads with "Bouncer-first", so a digest stopping one prompt short of the headline
feature is the stale-content problem rather than acceptable lag.

**Which is the argument for making it mechanical.** The README's badge and table are checked
against `STAGE2-PROMPTS.md` precisely because a hand-maintained progress claim always
drifts; the site now has three such claims — the count, the meter width, and the "next:"
sentence — and none is checked. The cheapest fix is to extend rule 5 to `docs/index.html`
rather than to remember. Left in `PLAN.md`'s Still open list where the website entry put it,
now with the evidence that it drifted within a day.

## Decision — `htdocs/` on main, `gh-pages` for the published site

**Commit:** see PR  **Date:** 2026-08-07

Reverses the website entry's "`docs/` on `main`, not a `gh-pages` branch" from earlier the
same day. The reasoning there was sound and is unchanged; what changed is the requirement,
which is now that the directory be called `htdocs`. That is not a distinction GitHub Pages
lets you keep for free.

**The constraint that forces this: Pages' deploy-from-a-branch mode serves `/` or `/docs`
and nothing else.** There is no setting for an arbitrary folder. So `htdocs/` on `main` is
unservable, and reaching it needs one of exactly three things:

- rename it back to `docs/` — rejected, the name was the requirement;
- an Actions-based deployment, which *can* publish any path — written, then **rejected
  outright**: it is a workflow, and a deploy workflow is a fifth CI job on a day when CI was
  unavailable for five hours;
- a `gh-pages` branch whose *root* is the site — chosen.

Note the third also cannot hold `htdocs/`: a branch source serves that branch's root, so
`gh-pages` carries `index.html`, `style.css` and `CNAME` at top level. `htdocs/` is the name
on `main`, where the source lives; the published branch is a copy of its contents.

**What this costs, stated plainly rather than discovered later: the two are synced by hand.**
The earlier entry called an orphan branch "a second thing to keep in sync", and it is exactly
that — the objection was right, it has simply been outvoted by the naming requirement. A
change to `htdocs/` on `main` does not reach visitors until someone copies it across. Raised
in `PLAN.md`'s Still open list, where the cheap mechanical answer is also recorded: compare
the two trees in `check-docs.sh` and fail when they differ. That check does not exist yet.

**`CNAME` lives in `htdocs/` as well as on `gh-pages`**, so that the copy carries the custom
domain rather than depending on someone remembering it. Losing it un-points
`caravan.lacunaresearch.com` on the next sync, silently.

**DNS is not ours.** The subdomain resolves to Cloudflare addresses today, so publishing
needs a `CNAME` record for `caravan` pointing at `Lacuna-Research.github.io`, made at
Cloudflare by someone with access to it.

## Decision — the website source directory is `www/`

**Commit:** see PR  **Date:** 2026-08-07

Renamed from `htdocs/`, which had itself replaced `docs/` a few hours earlier. Recording the
third name because the second one's entry is already in this log and would otherwise read as
current.

**`gh-pages/` was asked for first, to match the branch, and was rejected on evidence.** A
directory of that name collides with the branch of that name in git's own argument parsing:

    $ git checkout gh-pages
    fatal: 'gh-pages' could be both a local file and a tracking branch.
    Please use -- (and optionally --no-guess) to disambiguate

That is the command someone types to go and look at the published branch, and it stops
working the moment the directory exists. Worse quietly: `git rev-parse gh-pages` stops
resolving to the branch and returns the path, so anything scripted against the ref begins
meaning something else without erroring. Tested in the working tree before recommending
against it, rather than asserted from memory.

**There is also no standard to match.** GitHub Pages blesses exactly two source folders, `/`
and `/docs`; `gh-pages` is a *branch* convention and `htdocs` is Apache's. So the rename
would have bought symmetry with the branch at the cost of colliding with it — and `www/` is
the older, shorter convention that collides with nothing and reads correctly beside
`Sources/` and `Scripts/`.

**Nothing about the published site changes.** Pages serves the `gh-pages` branch's *root*,
which still holds `index.html`, `style.css` and `CNAME`; only the name of the source
directory on `main` moved. The two trees stay byte-identical, which is still checked by
hand — see the open question in `PLAN.md`.

## Decision — `check-docs.sh` compares `www/` against the branch that is served

**Commit:** see PR  **Date:** 2026-08-07

Answers and removes the "the published site is synced by hand" question from `PLAN.md`.
Nothing copies `www/` to the `gh-pages` branch, and a deploy workflow was rejected, so the
failure mode was silent and slow: edit the site, merge, and visitors keep seeing the old one
until somebody happens to notice. Rule 10 makes it loud instead.

**It compares tree object IDs, not files.** Git has already hashed both sides, so `HEAD:www`
against `origin/gh-pages^{tree}` is one string comparison that covers additions, deletions
and edits at once. Only when they differ does it spend anything, listing the per-file blob
SHAs so the message names what to copy.

**The mode distinction is the part that took a second attempt.** The first version compared
`HEAD:www` unconditionally, and a test with a staged edit *passed the pre-commit hook* — HEAD
does not yet contain what is about to be committed, so the hook waved through a commit that
CI would reject a minute later. It now reads the index (`git ls-tree $(git write-tree) www`)
when there is no base ref, and `HEAD` when there is. Found by trying to make it fail rather
than by reading it, which is the same lesson as the harness bug earlier: a check nobody has
watched fail is a check nobody knows works.

**A missing `gh-pages` ref is a `skip`, not a failure.** A shallow or fresh clone genuinely
has no remote-tracking branch for it, and failing there would make the script hostile on a
first checkout. CI fetches it — `docs.yml` checks out with `fetch-depth: 0` — so the
authoritative run always compares for real. The skip prints, because a check that goes quiet
is a check nobody notices has stopped running.

**`CLAUDE.md` stayed at 99 lines.** The enforcement sentence was re-wrapped rather than
extended: adding the clause naively took the file to exactly 100 of its 100-line cap, which
is not headroom, it is a trap for whoever adds the next one. Pruned by tightening the same
sentence ("for every" to "per", dropping "progress" and "the") — the cap is meant to force
exactly that.

## Stage 2, prompt 5 — Queries and CTCP

**Commit:** see PR  **Date:** 2026-08-07

PM windows, and CTCP stops rendering as control characters.

### Decisions

**CTCP parsing went to `IRCProtocol`, not `IRCSession`.** `PLAN.md`'s module table has said
`CTCP` belonged there since stage 0 and it had never been true — only `ACTION` was handled,
in `EventTranslator.unwrapAction`. `CTCPMessage` is now a parser and a wire form in the pure
module, which CI builds on Linux. Same reasoning as prompt 1's colour tables: a wrapper
exercised only through a text view is one nobody exercises. `unwrapAction` survives as a
three-line shim over it, because the local-echo path wants `/me` unwrapped without caring
whether anything else was a CTCP. *Revisit if:* nothing. This is where the table said it goes.

**One rate-limit bucket per connection, not per sender.** A per-sender bucket behaves better
for the honest case — one flooder cannot silence replies to anyone else — and is defeated by
spreading the flood across a thousand spoofed sources, which is the only case the limit
exists for. Global is the direction that cannot be gamed. Burst 5, one token back every 5s:
a person typing `/ctcp` a few times never notices, and twenty requests produce five answers.
*Revisit if:* someone reports legitimate replies being dropped in a busy channel, which
would argue for a larger burst rather than a per-sender bucket.

**The throttle explains itself once per burst, not once per request.** Fifty suppressed
requests producing fifty "not answering" lines is the flood arriving by a second route.
`CTCPThrottle.Outcome.suppressed(firstOfBurst:)` carries the distinction, and the *requests*
are each still a line — which is what makes the flood visible at all.

**No `ERRMSG` for an unrecognised keyword.** The older specs suggest one. It is a free
amplifier for whoever picks the keyword, and it tells them which client they are talking to.
Silence instead. `CLIENTINFO` still advertises honestly, and a test walks its own list to
check every keyword in it is one the responder actually answers.

**A `NOTICE` never opens a query window; a `PRIVMSG` does.** Services, the bouncer and half
the network send notices, and a window per sender is how mIRC's status window came to exist.
A notice from someone you already have a window open with lands *in* it, which is NickServ
answering in the NickServ window. *Revisit if:* someone wants a `BouncerServ` window without
having spoken first — `/query BouncerServ` already does that.

**`/msg <nick>` opens the conversation window. mIRC's does not.** The deviation is forced:
under `echo-message` the server hands back a copy of what we sent, it arrives through the
inbound path, and it opens the window. Matching that on a network without the capability is
the only way the client behaves the same on both. Recorded because it *is* a departure from
the client this one is modelled on. `/query` remains the way to open a window with nothing
to say.

**`QueryBuffer` is its own type, not `ChannelBuffer` with an empty roster.** A query has no
membership, no topic and no modes; hollow versions of all three would invite code that reads
them. The cost is a second array on `ConnectionViewModel` — which is also how "queries sort
after channels" (§12) became the order two arrays are concatenated in rather than a
comparator that has to be right everywhere it is written.

### Learned

**The mirrored casemapping was stale where it mattered most.** `ConnectionViewModel` learns
the server's mapping from events that carry a folded name, so before any channel event it is
still the `ISUPPORT` default. Queries are keyed by nick and can exist before any channel
does: `/query bob` keyed the buffer under `rfc1459` while bob's reply arrived folded under
`ascii`, and the same person got two windows. `openQuery(with:)` is `async` now and reads the
mapping off the actor. Caught by a test that compared two `SidebarItem.query` values and
found them unequal — `IRCNick`'s equality includes its mapping, which is exactly the bug
worth surfacing rather than papering over, as its doc comment already claimed.

**`Duration.seconds` already existed** on `BackoffPolicy`'s extension. A second copy compiled
fine and would have been a redeclaration a module later.

### The live run, against Libera over TLS

Connected from a hand-written config the sheet pre-filled and did not clobber. A scripted
Python peer — not a second Caravan, since macOS will not foreground two copies of one bundle
— held a conversation, which opened a window of its own with the bullet sigil, sorted under
its network, its header band showing the message count and both ends of the conversation.
One `VERSION` was answered once. Twenty in a burst were answered **exactly five times**, with
one line saying why and not fifteen. A second pass, paced inside Libera's own message
throttle, got correct answers to `VERSION`, `PING` (argument echoed verbatim), `TIME`,
`CLIENTINFO` and `USERINFO`; `SOUND` and `ACTION` drew none. ⌘W closed the conversation with
nothing on the wire, and the toolbar said "Close Conversation" rather than "Close Channel".

**Fifty at once was not sent, and could not be.** Libera throttles the *sender*: the first
pass' twenty produced a stream of `*** Message to caravan-q5 throttled due to flooding`.
Fifty-at-once is covered instead by `CTCPSessionTests.floodIsThrottled`, which does it over a
real socket against a scripted server. Worth saying plainly: a public network will not let
you rehearse the attack its own limits exist to stop.

### Three defects the live run found, and no test would have

1. **The header band hid the useful half.** It shrinks to two lines, and the summary read
   count-then-`First` — so the opening line of the conversation was visible and the most
   recent one was behind the chevron. `Latest` comes second now. §14 lists "first and last"
   in that order; the band does not, and the reason is written where the code is.
2. **Our own auto-reply read as somebody answering us.** Libera negotiates `echo-message`, so
   the `NOTICE` we send comes back — and rendered as `*** CTCP reply from caravan-q5`, our own
   nick, as though a stranger had answered a question we never asked. Now `.ownCtcpReply`:
   `*** CTCP reply to caravan-peer6: ...`, the recipient in `$nick`, the same thing
   `ownPrivateMessage`'s arrow does. Kept rather than suppressed — it is what made the rate
   limit visible in the window at all.
3. **`VERSION` reported "macOS Version 26.5.2 (Build 25F84)".**
   `operatingSystemVersionString` includes the word and the build number. Assembled from the
   numeric components instead: `Caravan 0.1.0 (macOS 26.5.2)`.

All three are now unit tests. None of them could have been: two are about what a line *says*,
and the third about which line a two-line clamp keeps.

## Stage 2, prompt 6 — Activity and navigation at scale

**Commit:** see PR  **Date:** 2026-08-07

Thirty buffers, navigable without the mouse. GUI-DESIGN-NOTES.md §3, §9 and §11.

### Decisions

**`ChatBuffer` is a protocol now, and the status window is an object.** Prompt 5's
carry-forward said the third occurrence would earn it, and this is the third: `ChannelBuffer`,
`QueryBuffer` and — newly — `StatusBuffer`, which until now was a `MessageLogController` and
an `InputState` hanging off `ConnectionViewModel` rather than a thing. Four features wanted a
uniform element at once (the flat list, the activity state, MRU order, binding identity), and
a status window that was the one exception meant a special case in four places instead of one
indirection. `ConnectionViewModel.log` and `.statusInput` still exist and forward, so nothing
holding a network's scrollback had to change. `destinations(for:)` returns buffers rather than
log controllers, which is what lets an arriving line raise the *buffer's* activity.

**A private message is a highlight, not merely a message.** §3 does not say so; §18 does, by
grouping "highlights and private messages" as the two things worth notifying about. A query
that could only reach `message` would wear the same colour as somebody chatting in `#swift`,
and the whole reason a PM has its own window is that it is addressed to you. *Revisit if:*
prompt 13's configurable triggers make this a setting, which is where it belongs long-term.

**Activity rises and never falls until you look.** A buffer holds the *most urgent* thing
since you last looked, so a join arriving after a highlight does not quietly downgrade it. The
selected buffer never accumulates one at all, which is what makes the state mean "since you
last looked" rather than "ever".

**A mention is a word, not a substring.** `bobbins` and `bob2` do not mention `bob`. Without
the boundary rule a short nick highlights on almost every line, which trains people to ignore
the state entirely — and the state is the thing prompt 13's whole notification story rests on.

**⌘1–9 bind to `host:port`, not to the display name.** §11 says a binding attaches to
"network plus buffer name" and survives restarts. `displayName` comes from `ISUPPORT
NETWORK=`, which the server owns and can change under you; `id` is a fresh `UUID` every
launch. `host:port` — plus `[bouncer-network-id]` where there is one — is what the user typed
and what `AppModel.connect(using:)` already treats as network identity. **This is knowingly
provisional:** `PLAN.md`'s "Still open" has wanted a stable *user-facing* network name since
stage 1, the server-list prompt answers it, and `binding.N` keys migrate then. Written down
because `caravan.conf`'s keys are public API and this one will move.

**The buffer name in a binding keeps its `#`.** `#bob` and `bob` are different buffers, and a
bare name could not say which was meant — so the config value is `host:port/#swift`, and a
status window is the network with no buffer part at all.

**Ctrl+Tab freezes the MRU order while the modifier is held.** The Windows Alt-Tab model §9
asks for. Committing each step would reshuffle the list under the walk, so the second tap
would return you to where you started and walking further back would be impossible.

### Learned

**A local `NSEvent` monitor is not optional for Ctrl+Tab.** SwiftUI can bind a key *press*;
the model §9 wants turns on the modifier being *released*, which is what separates "hold and
keep tapping" from "tap twice", and there is no SwiftUI expression of that. Tab is also a
focus-navigation key AppKit consumes before any responder sees it. `CtrlTabMonitor` is local
and scoped to this app's own events — nothing observes other applications and no accessibility
permission is involved.

**`NSEvent.removeMonitor` cannot be called from `deinit`** under Swift 6: `deinit` is not
isolated and the handles are non-`Sendable` `Any?`. The monitor is torn down from
`onDisappear` instead, which is the lifetime that actually matters.

### The live run: thirty channels across Libera and OFTC

Fifteen `##caravan-nav-N` on Libera and fifteen `#caravan-nav-N` on OFTC, both groups
collapsed to a two-row tree, a scripted Python peer supplying chatter in one channel, a
nick-mention in another and a private message. Every navigation path exercised by keyboard
only: ⌥⌘A walked the unread ones and auto-expanded a collapsed group to do it; ⇧⌥⌘A skipped
fourteen merely-active channels straight to the one holding a mention; ⌘K found buffers by
typing and Enter; ⌘7 and ⌘9 — seeded by hand into `caravan.conf` before launch, one per
network — reached their buffers and showed their digits in the tree, which is nine *global*
slots demonstrated across two networks; Ctrl+Tab toggled the last two, and holding Ctrl
through two taps walked three deep and committed on release. The collapsed network row wore
its hidden child's highlight, badge and all. The hand-written config kept its comment and its
two binding lines unchanged.

**Not verified: the `Bind to ▸ 1…9` submenu itself.** SwiftUI's `.contextMenu` exposes no
`AXShowMenu` action on these rows — the row elements report an empty action list — so it
cannot be driven from this harness. Binding is verified through the model and through the
config round-trip, and the digit it produces is verified in the tree; the menu that invokes it
was read rather than clicked. Said plainly rather than filed under "verified live".

### Three defects the live run found

1. **The highlight state was invisible on this machine.** It used `controlAccentColor`, on the
   reasoning that the unread rule already uses the accent and therefore it already means
   "the thing you are looking for". This machine's accent is **Graphite**, so the most
   important of four colour-coded states resolved to grey and was indistinguishable from an
   ordinary row. Now pink — not red, which is errors, and not orange, which the connection
   indicator uses a few pixels away on the same row. **A state whose whole job is to be
   distinguishable must not depend on a user setting that can be colourless.** The unread rule
   can afford the accent because it is a line across the window, findable by shape.
2. **⌥⌘H is macOS's Hide Others.** Next-highlight was bound to it, the App menu won, and the
   key silently did nothing — nothing in the build reports a collision with a system shortcut.
   Next-highlight is ⇧⌥⌘A now: the same key as next-unread with one more modifier, which reads
   as "the same thing, but only the ones addressed to me".
3. **Three ranking faults in the ⌘K palette**, all found by using it. With an empty query every
   score tied and the list fell back to shortest-then-alphabetical, so it opened with
   `##caravan-nav-10` above `##caravan-nav-2` — an unfiltered palette now keeps the tree's
   order. Two equally good matches ignored activity, so typing `nav-11` with a channel of that
   name on each network landed on the quiet one rather than the one holding a highlight —
   ties break on activity now. And the obvious way to disambiguate, `libera nav-11`, matched
   nothing at all, because the candidate has a slash where the space is; a space in the query
   is now dropped rather than matched, so it means "and then, later".

All three are unit tests. The first two could only have been found by looking — one of them
only by looking *on a machine configured this way*, which is worth remembering the next time
a colour is chosen from a semantic role rather than a value.

## Stage 2, prompt 7 — Windows and chrome

**Commit:** see PR  **Date:** 2026-08-07

The other half of the multi-window model: a buffer can leave the window, the tree can be
reordered by hand, and the window has real chrome.

### Decisions

**A detached window holds exactly one buffer and has no tree.** "Detach this", not "open a
second copy of the app" — §1 keeps the single sidebar-driven window as the primary
metaphor, and a second tree would be a second place for the selection to live and a second
answer to "where am I". It reuses the same view bodies the main window's detail pane uses,
so a detached channel is not a second implementation that can drift.

**One affordance, and it takes a `SidebarItem`.** §10 asks that the canvas's standalone
mode be "the *same general affordance* used to detach a chat buffer", not a mechanism
special-cased for it. `SidebarItem` already spans buffers and the canvas, so `detach(_:)`
takes one and the tree row, the View menu and the toolbar all call it. `showSettingsAndDebug()`
is the single place §10's "⌘0 focuses the window instead" had to be taught, exactly as
`PLAN.md` predicted.

**Closing a detached window *is* reattaching.** Not a second, destructive meaning of
"close": a buffer that existed in neither place would be one you could no longer reach.

**A detached buffer never accumulates activity, whether or not its window is key.** The
main window's selection has never been conditioned on key-ness either — a buffer you are
looking at stays clear while the app is in the background — and one rule that is sometimes
generous beats two rules that disagree. *Revisit if:* someone reports missing a highlight
in a detached window buried behind other apps.

**Channels and conversations are reordered separately**, which preserves §12's
channels-before-queries rule through any amount of dragging. That rule exists to keep
channel positions stable as transient PMs come and go, and a drag that could interleave
them would give it away for nothing.

**The saved order is a preference list, not the order.** A buffer named in it takes the
position it names; one that has never been dragged keeps arriving in join order at the end.
So joining a channel you never reordered does the obvious thing, and rejoining `#swift`
after a reconnect does not send it to the bottom of a list you spent time arranging.

**`bindingNetworkKey` became `networkKey`**, because two features now key on it — ⌘1–9
bindings and the tree order. Both inherit the same caveat and both migrate together when
the server-list prompt answers `PLAN.md`'s stable-network-name question.

**⌘W moved from a toolbar button to the menu bar.** A customizable toolbar cannot hold a
keyboard shortcut: dragging the button away would take the key with it. It is also disabled
unless the main window is key, since with a detached buffer in front ⌘W means "close this
window" and acting on the main window's selection would close a buffer nobody was looking at.

### The live run, against Libera

Three channels, detached and reattached by keyboard and by menu; the canvas ejected and ⌘0
confirmed to raise its window rather than take over the chat area (§10); a manual tree order
**written into `caravan.conf` by hand before launch** — the half of "persisted" the app
cannot demonstrate on its own — with the channels joined `a, b, c` and coming up `c, a, b`,
and the ⌘K palette listing them in the same order, which is prompt 6's carry-forward
satisfied. The menu bar carries Connect, Disconnect, Close Buffer, Close Network, Detach,
the nick list and all of Navigate. The hand-written config kept its comments and its order
line unchanged.

**Not verified: an actual drag.** System Events cannot synthesise a drag, so the reorder was
exercised through the model and through the *load* path live; the mouse gesture itself was
not. **Nor the customization palette sheet** — clicking "Customize Toolbar…" through the
accessibility API did not take, the same limitation prompt 6 hit with the `Bind to` submenu.
Its *presence* was confirmed by opening the toolbar's context menu and photographing it.

### Five defects the live run found

1. **⌃⌘D is macOS's "Look Up in Dictionary".** The obvious mnemonic for detach, bound and
   displayed correctly in the menu with its shortcut, and it simply never fired — a
   system-wide text service swallows it first. Now ⌃⌘O. **The second time this stage has
   been caught by a system shortcut that reports no conflict at build time**, after prompt
   6's ⌥⌘H/Hide Others. Worth a habit: a new shortcut is not done until it has been pressed.
2. **`.primaryAction` toolbar items are not customizable.** They pin to the trailing edge
   and never appear in the palette, which is the whole of what §8 asks for. `.secondaryAction`
   is the customizable body of the toolbar.
3. **`.defaultCustomization(.hidden)` is ignored on macOS 26.5.** Every item declared showed
   regardless. Rather than ship a call that does nothing, the toolbar now *declares* only
   §8's minimal set and everything else lives in the menu bar — which is §8's other half and
   is the thing a customization palette can never take away.
4. **Detached windows came back on relaunch, onto buffers that no longer exist.** A detached
   window names a connection whose identity lasts one run, so a restored one always names a
   dead network — the run watched last session's `##caravan-win-a` reappear on a launch that
   had not connected to anything. Neither `defaultLaunchBehavior(.suppressed)` nor
   `restorationBehavior(.disabled)` stopped it, so restoration is made *harmless* instead:
   the window adopts itself into the model if its target is real, and dismisses itself if not.
5. **Detaching the canvas left the main window claiming "Not connected".** The fallback was
   "this row's network", the canvas belongs to no network, so the selection went nil — and an
   empty selection is also how the app says there is nothing to show. It falls back to the
   first connection now.

### Also fixed: a real race in prompt 5's suite

`CTCPSessionTests.floodIsThrottled` failed once here and passed on six re-runs. It was not a
flake to shrug at: the test waited for the *client* to observe fifty requests and then read
what the *server* had received, and the reply round trip is not synchronised with the event
count at all. It now waits for a reply to actually arrive. `BUILD-LOG`'s own note from prompt
4 — that an intermittent failure is "the kind of failure it is very tempting to re-run and
call a flake" — is what made me go and look.

## Stage 2, prompt 8 — Commands and modes

**Commit:** see PR  **Date:** 2026-08-07

The command table filled out, and the mode layer half of it fronts.

### Decisions

**`/ban` names a person; the connection resolves the mask.** A useful ban is `*!*@host`,
and banning `bob!*@*` is defeated by `/nick bob2`. The host lives in the channel roster,
the roster lives on `ConnectionViewModel`, and `CommandParser` is pure and should not grow
one. So `CommandAction.ban(channel:subject:isSet:kickReason:)` says what was asked for and
the connection works out what it means — which is the shape prompt 2's carry-forward asked
the whole enum to keep. A subject that already looks like a mask passes through untouched,
and a nick the roster does not know falls back to `nick!*@*`: a weaker ban beats an error.

**`/kickban` bans before it kicks.** Kicking first leaves a window, however small, in which
they can rejoin — and closing that window is the only reason it is one command rather than
two.

**Membership modes batch to `MODES=`.** `/op a b c` is one `MODE #swift +ooo a b c`, split
across as many lines as `ISUPPORT MODES=` allows and defaulting to three where the server
does not say. One line per nick would work and would be three times the traffic and three
times the flood risk, which is the thing `MODES=` exists to bound.

**`/amsg` and `/ame` go to every channel on every *connected* network.** Across networks
because "tell everyone I am going out" is not a per-network thought, and only channels we
are actually in because a parted buffer still in the tree would earn a 404. Sent one
channel at a time rather than as a comma list, so flood protection and the local echo see
them as the separate messages they are.

**One list dialog with a picker, not four.** 367, 346, 348 and 728 are the same numeric
shape four times over — a channel, a mask, optionally a setter and a time. Four
near-identical dialogs would be four places to fix the same bug. `IRCEvent.listModeEntry`
carries the mode letter, and 728 gets special handling only because it puts that letter in
a column of its own, having been invented later and by someone else.

**Three commands are deliberately half of what their name suggests**, and the prompt's
"Do not" says so: `/list` sends `LIST` and renders the numerics while the *browser* is a
later prompt; `/away` and `/back` send the line while auto-away and the away log are a
later prompt; and **`/ignore` is not in the table at all** — the matching machinery belongs
with the ignore list, and a half-built `/ignore` that silently did nothing would be worse
than one the server rejects out loud. `PLAN.md` item 14 lists it; the note now says where
it went.

**`EXCEPTS` and `INVEX` are read from `ISUPPORT`, and may arrive bare** — `EXCEPTS` alone
means "yes, at `e`". `nil` means the server never mentioned it and does not have the list,
which is a different thing from having it at the default letter and is why they are
optional rather than defaulted. Quiet is offered regardless: no token announces it, and the
networks without it answer with an error rather than silence.

### Learned

**`Character(String)` traps unless the string is exactly one character.** 728 carries a
mode letter in a column, and a server sending an empty or two-character one would have
crashed the client. Caught by writing the test for it rather than by it happening.

**The stale-build linker failure again**, after changing `Channel`'s stored properties. Same
signature as the enum-ordinal case already in memory: `trash .build`, not a bug.

### The live run, against Libera on a channel we own

`/op` and `/deop`; `/voice caravan-cmd caravan-peerm3` going out as **one `+vv` line for two
people**, which is the batching claim proven rather than asserted; `/ban caravan-peerm`
resolving to `+b *!*@189.146.108.51` from the roster; `/ban badactor` on someone absent
falling back to `badactor!*@*`; `/unban` with an explicit mask; the ban list read back with
its setter and timestamp; `/mode +m` taking effect and showing up ticked in the sheet; and
the sheet's Lists tab fetching the ban list on appear and saying "Nobody is banned from
this channel" rather than showing a spinner forever.

**Two rounds of the live run were wasted on my own test setup**, which is worth writing
down: opping someone already opped proves nothing, because Libera drops no-op changes from
the echo; and banning `*!*@<my host>` locked out the scripted peer, which runs on the same
machine. The batching claim needed two unvoiced people in the channel at once before it
could be seen at all.

**Not verified live: the sheet's Add field**, and the invite/except lists — Libera advertises
both, but this channel had no entries to read and putting some there proves less than the
ban path already did.

### Two defects the live run found

1. **List entries rendered as `*** Channel modes for : +b *!*@…`** — the wrong sentence, and
   with an empty channel, because they reused `channelMode`'s template and never filled in
   its `$channel`. They have their own `LineKind` now and read `Ban list for #swift:
   *!*@evil.example (set by carol on …)`.
2. **A channel does not have a `+b`; it has a ban list.** `Channel.apply` recorded any mode
   with an argument in `modeArguments`, so the modes sheet's own header read `+Cnstb
   badactor!*@*` — and each new ban overwrote the last, making the "value" whichever ban was
   set most recently. `CHANMODES` group A is now consulted and list modes are skipped. Found
   by reading the sheet I had just built, which is the argument for building the UI that
   displays a thing in the same prompt as the thing.

### Three test races, all mine, all fixed

Written down because they are the same mistake three times and the shape is worth
recognising: **waiting on the wrong thing.** One waited on `!pendingListModes.contains("b")`,
which is true before anything arrives at all; one waited for the entries and then asserted
on the end marker, which comes after them; one waited on the collected data and then read
the *scrollback*, which is written later in the same handler. All three passed under
`--filter` and failed in the full suite, which is slower and therefore more honest.

## Stage 2, prompt 9 — Things you can do to what is in the buffer

**Commit:** see PR  **Date:** 2026-08-07

Context menus on nicks, links and the buffer itself, and the URL catcher behind the links
the scrollback was already drawing.

### Decisions

**A menu item is a command string.** Every item on a nick submits `/whois bob`, `/op bob`,
`/kickban bob` through `AppModel.submit` — the same path a typed line takes — rather than
calling into `ConnectionViewModel`. Two things follow. The menu cannot drift from the
command, so `/op` fixed once is fixed in both; and stage 3's script-driven menus become a
change to `BufferMenu.items(for:channel:canSetModes:)` rather than a rewrite of any
plumbing. Slap needed no new command at all: it is `/me slaps …`, which the table already
carries. Revisit only if some future item has no command form — and the answer then is
probably to give it one.

**The menu table is pure and returns groups, not a flat list.** `BufferMenu` takes a
`BufferTarget`, a channel and a `canSetModes` flag, and answers `[[BufferMenuItem]]` where a
group boundary *is* a separator. That keeps divider logic out of both renderers — SwiftUI's
`BufferMenuItems` and AppKit's `NSMenu.buffer(_:perform:)` — and means the whole table is
tested as data rather than by putting a window on screen.

**Operator items are disabled, never hidden.** A menu whose contents come and go teaches
nobody what the client can do. The live run made the case better than the argument does:
the same menu, opened twice a minute apart, greys out seven items the moment you lose `+o`.

**`canSetModes` moved onto `ChannelBuffer` and takes a nick.** It was private to
`ChannelModesSheet` *and* asked `model.activeConnection?.currentNick` — the tree's
selection, not the sheet's own network. `ChannelBuffer.canSetModes(as:)` now answers for
whichever nick it is handed, and three callers share the one guess.

**`BufferActions` holds references, not a snapshot.** The struct the buffer views hand to
the nick list and the scrollback carries the `ChannelBuffer`, not a `Bool` — because the
scrollback's menu is built when the pointer is over something, long after the view that
supplied it was laid out. A `canSetModes` snapshotted at build time would still say "you
are not an operator" ten minutes after somebody opped you. The first draft did exactly
that, and the live run is where it would have shown.

**The scrollback's hit test reads the text storage.** `LineRenderer` already leaves a
`NickColumn` on every nick column and `applyLinks` already leaves a `.link` on every URL it
detects, so `ScrollbackTextView.menu(for:)` is one attribute lookup rather than a second
parse of text parsed twice already. `target(in:at:)` is static and takes the storage so the
attribute half is testable without a laid-out window; the geometry half — which character a
point is over — is TextKit 1 only and answers `nil` under TextKit 2, degrading to the
buffer's own menu rather than crashing.

**A right-click on or beside a selection keeps AppKit's own menu.** Copy, Look Up and
Services are what a selection means on macOS, and replacing them with "Whois" for whichever
word is under the pointer would be this client overriding a system convention in the one
view where selecting text is the point.

**The catcher collects inbound only, off the rendered line.** It walks the `.link` runs of
each line as it lands rather than running a second `NSDataDetector`: a second detector is a
second opinion about what a URL is, and the two would eventually disagree with the underline
the user can see. Outbound is deliberately not collected — what you typed is in your own
command history and in the buffer in front of you, and catching it would mean a second seam
in `echo(_:from:capabilities:)`, which has no buffer name in hand. One line to add if it
turns out to matter.

**Identity is the URL *and* the buffer.** The same link posted in two channels is two rows,
because "where did I see this" is half of what the window is for. A repeat in the *same*
buffer moves to the front and takes the new time rather than adding a row — otherwise a bot
reposting hourly is the whole window.

**The catcher is a sheet, and it remembers which window opened it.** Not a third kind of
window: §1 keeps the single sidebar-driven window as the primary metaphor, and the modes
sheet is the precedent. `AppModel.urlCatcherPresentation` records the `KeyWindow` at the
moment it is asked for, and `RootView` and `DetachedBufferView` each present only their own
— a plain `isShowing` flag would put the sheet on the main window, quite possibly behind
the one holding the link. Recorded at open time rather than read from `keyWindow` while
presenting, because presenting a sheet is itself something that changes which window is key.
Worth revisiting if anyone wants the catcher open *beside* a conversation; the answer then
is the `SidebarItem` detach mechanism, not a bespoke window.

**Open All asks above five.** Twenty browser tabs from one mis-click is not something a
client should be able to do without a question, and five is where "a handful" stops.

### The defect this prompt fixed on the way past

**Everything a buffer view sent went to the tree's selection.** `AppModel.submit(_:from:)`
resolved its connection from `selection`, so a detached channel window on one network with
the main window pointed at another sent every typed line to the wrong server — and the
context menus would have inherited it exactly. `submit` now takes `on connection:`, and
`ChannelBufferView`, `QueryBufferView` and `StatusBufferView` pass the connection they are
showing. The same lookup was wrong in three more places, all fixed with it: `/clear` cleared
whichever buffer the tree had selected (`clearScrollback` now takes the connection and asks
`ConnectionViewModel.log(for:)`, which is public for it); `completionSources` offered the
selected network's channel names in a detached window's completion; and `ChannelModesSheet`
read `lastKnownCapabilities` and `currentNick` off `activeConnection`.

`DetachedBufferView` also resolves its connection from `item.connectionID` rather than
letting the views reach for `activeConnection`, which is what makes the fix structural
rather than three careful call sites.

### Deliberately not built

**Ignore**, which `PLAN.md` item 17 lists in this menu. The matching machinery is prompt
13's, with the ignore list, and an item that silently did nothing is worse than no item. A
carry-forward note on prompt 13 names the file and the group to add it to.

**DCC chat/send**, also listed in item 17 — stage 3, item 31, and a transport problem rather
than a menu one. Noted on that item.

**A reason prompt for Kick and Ban.** The default kick reason is an Options setting and
Options is prompt 10; until then the parser's default stands, which Libera showed as
`caravan-peer9 was kicked … (caravan-peer9)` — mIRC's convention, the target's own nick.

**No new keyboard shortcuts.** This stage has lost two to system bindings that report no
conflict at build time. "URL Catcher…" is a View-menu item without a key; the scrollback's
right-click is the affordance it is a fallback for.

### The live run, against Libera in `##caravan-p9` with a scripted peer

Every acceptance item except the last, and it went cleanly:

- The MOTD's three URLs arrived underlined and clickable, with working link tooltips, and
  accessibility exposes them as real link elements inside the text area.
- The nick list's menu on `caravan-peer9`: all four groups with their separators. **Op**
  from it produced `+o caravan-peer9` and the nick list redrew as `@caravan-peer9`; then
  **Deop** and **Voice**, both landing.
- The scrollback's menu on the `<caravan-peer9>` column produced the same menu — the
  `NickColumn` hit test working against a real text storage — and **Kick** from it kicked.
- **Slap** rendered as `* caravan-p9 slaps caravan-peer9 around a bit with a large trout`.
- Deopping ourselves and reopening the menu greyed out Op, Deop, Voice, Devoice, Kick, Ban
  and Kick and Ban, leaving Whois, Query and Slap alone. This is the assertion that the
  menu recomputes rather than snapshots.
- **Copy Link** put exactly `https://example.com/prompt-nine` on the pasteboard; **Open
  Link** opened it in the browser.
- The catcher opened scoped to This Buffer with the channel's two links, and **Everywhere**
  showed five including the MOTD's three under `Libera.Chat on Libera.Chat`. **Copy All**
  produced the five newline-separated, newest first. With six caught, **Open All** asked
  "Open 6 links in your browser?" — cancelled rather than opening them.
- Double-clicking the peer in the nick list opened and selected the conversation.
- Detached the channel window, right-clicked a link in it, and chose URL Catcher: the sheet
  presented on the **detached** window and the main window had none. That is the per-window
  presentation claim, checked the only way it can be.

**Not verified live: the two-network case**, where the tree is on network A and a detached
window on network B sends something. Covered instead by `BufferConnectionTests`, which runs
two scripted servers over real sockets and asserts the `WHOIS` and the `KICK` arrive at the
second and never at the first — the same claim, and more precise than an eye on two windows.
**Also not verified live:** that a right-click inside a selection falls through to AppKit's
menu; selecting text needs a synthesised drag, which System Events cannot do — prompt 7
recorded the same limit for the tree's reorder.

### Learned

**System Events cannot right-click.** `click at` is left-button only and there is no
right-click verb, so a twenty-line Swift helper posting `rightMouseDown`/`rightMouseUp`
`CGEvent`s was needed to open a context menu at a point at all — and a second one setting
`mouseEventClickState` to 2 for the double-click. `AXShowMenu` works for the SwiftUI rows,
which have accessibility elements of their own; it cannot target a *character* inside an
`NSTextView`, which is exactly what the scrollback's menu is about.

**`keystroke` silently does nothing until the field is focused**, and `set value of text
area` followed by `key code 36` is the reliable pair. Two commands were typed into the void
before this was noticed — the same shape as the wrong-binary lesson: check that what you did
landed, not that the command returned.

**`NSMenuItem.target` is weak.** The closure-carrying handler needs `representedObject` as
well, or the action is deallocated between building the menu and choosing from it. There is
a test for it, and it exists because the first version had the bug.

**`autoenablesItems` has to be off.** Otherwise AppKit asks the responder chain whether each
selector is valid and greys out every item whose target is not a responder — which, with a
closure handler, is all of them.

## The website's progress numbers, made mechanical

**Commit:** see PR  **Date:** 2026-08-07

Answers the "the website's progress numbers are hand-maintained" question, which is now
deleted from `PLAN.md`'s **Still open** list.

### The answer: check them, do not remove them

The open question offered two ways out — grow the badge check a sibling that greps
`www/index.html`, or take the numbers off the page. **Checked**, because the numbers earn
their place: the site is the only thing a stranger reads, "9/17 prompts" and a meter is the
fastest honest answer to "is this real yet", and a project that deletes its progress
indicator to avoid maintaining it has solved the wrong problem. What was wrong was never
that the page had numbers; it was that three places wrote the same number down and only two
were checked.

So `site_progress` sits in `Scripts/check-docs.sh` beside the README badge and table rules
it mirrors, called from both status-line blocks. `README.md` and `www/index.html` are now
checked against `STAGE1-PROMPTS.md` and `STAGE2-PROMPTS.md` by the same rule, at the same
moment, and neither can move without the other.

**It reads the page's numbers rather than grepping for the expected string.** A grep can
only say "not found"; this says `website stage 2 says '4/17' prompts, status line says
9/17`, which is the difference between a check that fails and a check that tells you what
to type. Both fields are scoped to their own `<h3>Stage N` section, because there are three
stage cards and an unscoped match reads stage 1's meter for stage 2.

**The meter width is derived, not eyeballed:** one decimal place, which is the convention
the page already followed — 4/17 really is 23.5% — with a trailing `.0` trimmed so a
finished stage reads `width:100%` rather than `width:100.0%`, matching what stage 1 already
had. That the formula reproduces the existing hand-written 23.5% and 100% exactly is the
evidence it is the right formula rather than a new one imposed on the page.

**The prose beside the numbers is deliberately not checked.** "Formatting codes and the
99-colour palette ✓ · … · next: options, the server list, …" is editorial — it says what
the stage *is*, not how far along it is, and a machine cannot write it. It is stale less
easily than a number and it is now adjacent to a number that cannot be stale at all, which
is the cheapest available warning that it needs rereading.

### The publish step is a script now

`Scripts/publish-site.sh`. Rule 10 has failed with the advice "copy `www/*` to the root of
gh-pages" since it was written — a manual step described in prose, and therefore a step
done slightly differently each time it is done at all. The error message now names the
script.

It works in plumbing rather than checking anything out: `git commit-tree` on the tree object
`$ref:www` already names, pushed to `refs/heads/gh-pages`. Two properties follow. **The tree
pushed is the same object rule 10 compares**, so a successful publish cannot leave the two
disagreeing — there is no copy step to get wrong. And nothing touches the working tree, so
it is safe to run mid-branch, which matters because of the ordering below. `DRY_RUN=1` says
what it would do; the push is not forced, so a rejection means somebody else published and
this would have erased it.

### The ordering is backwards from what you would guess, and has to be

Rule 10 compares the *branch's* `www/` against the published `gh-pages`. So a PR that
changes the site is red until `gh-pages` is updated — the site is published **before** the
PR merges, not after. That reads wrong for a second and is right: it means the live site is
never behind what a merged `main` claims, only ever briefly ahead of it, and "ahead" for a
progress number means "correct sooner". Publishing after the merge would need a deploy
workflow, which the rule 10 comment records as considered and rejected.

Worth knowing the failure mode this creates: while the site is published and the PR is not
yet merged, `main` itself disagrees with `gh-pages`, so any *other* open PR goes red on
rule 10 through no fault of its own. Acceptable at this project's one-PR-at-a-time pace,
and cheap to notice; if it ever bites, the answer is to compare against the base ref's
`www/` rather than the branch's.

### What the page actually said

**4/17, meter at 23.5%, against a `main` at 9/17.** Five prompts of drift — worse than the
one-prompt drift that first raised the question, which is what an unchecked number does
given time. The prose had rotted with it: "next: queries and CTCP, activity states and a ⌘K
switcher, the full command set, mode tracking" listed four things that were all done.
Corrected here to 9/17 and 52.9%, with the sentence rewritten to name what shipped through
prompt 9 and what is genuinely next.

## Stage 2, prompt 10 — Options

**Commit:** see PR  **Date:** 2026-08-07

mIRC's tabbed options on the Settings & Debug canvas, and the density and zoom model §15.5
has been waiting for.

### Decisions

**A tab exists when it has something in it.** mIRC has eight; this ships five — Connect,
IRC, Display, Colours, Other. Sounds is prompt 13's and Logging is prompt 12's, and an
empty tab teaches the user the client is unfinished rather than that the feature is coming.
Adding one is a case in `OptionsPane.Tab` plus a `@ViewBuilder` pane, since the enum is
`CaseIterable` and drives the picker; both prompts have a note saying exactly that. A
segmented picker like `ChannelModesSheet`'s rather than a second sidebar — it stops scaling
around seven tabs, and that is when to reconsider.

**Connect is identity; servers belong to the server list.** Prompt 3's note sent
authentication here on the grounds that prompt 11 retires the Connect sheet. Prompt 11 is
also where the *server list* lands, and a SASL method, an account and a password are
per-server while Options is global — so the split is on that line: nickname, alternate,
ident and real name here, everything per-server there. `ConnectionSettings.rememberIdentity(in:)`
writes exactly those four keys and deliberately not the host, the port or the Keychain
secrets, and there is a test asserting the absence rather than only the presence.

**Sixteen swatches, not ninety-nine.** The stage 3 note asked where a 99-swatch grid
belongs; the answer is that it was the wrong shape. §5 puts per-index overrides on top of
the two 16-colour tables and leaves 16–98 fixed by the specification, so only 0–15 are the
user's to retune — and sixteen wells fit a form without dwarfing it. Persisted as one
`chat.colour.N = RRGGBB` key per overridden index, absent when not overridden, so the file
stays as short as what was actually changed. **Per-nick overrides stay out**: the affordance
is "Set Colour…" on a nick's own context menu, which is `BufferMenu` and therefore stage 3's
scripted-menu work, not a row in a settings form.

**Removals are read back from the file, not diffed against the old value.** A
`chat.colour.7` somebody added by hand is a key this setting owns and must be able to
clear, and it was never in `oldValue` to be diffed against. `ConfigFile.keys(withPrefix:)`
exists for that, and it is the first setting shaped as a *set* rather than a scalar — worth
knowing for prompt 13, whose keyword lists have the same problem and a harder version of it.

**Zoom is a multiplier, not a second size.** `effectiveFontSize` is `fontSize * zoom`,
clamped to the font-size range at the end so zooming cannot reach a size the stepper could
never produce. Steps are multiplicative so out-and-back returns *exactly* to 1.0 rather than
nearly; additive steps drift. Actual size is ⌥⌘0 because §10 gave ⌘0 to the canvas, and ⌘+
is declared twice — as `+` and as `=` — because the key is physically `=` and declaring one
of them makes the shortcut work for about half the ways people press it.

**Density is line height, expressed as a multiplier over the font's natural one.** Compact
is 1.0 — the natural height — so no preset can make a line shorter than its glyphs need,
which is §15.6's "never clamp a requested size downward" holding by construction rather than
by care. `minimumLineHeight` is what opens the lines; `maximumLineHeight` takes whichever is
larger of the density and the existing Zalgo clamp, since a maximum below the minimum is a
paragraph style that draws nothing.

**One place builds the chat font.** Four call sites used to write
`ChatFont.nsFont(family: settings.fontFamily, size: settings.fontSize)`, which would have
been three chances to forget zoom the moment zoom existed. `ChatSettings.chatNSFont` and
`.chatFont` are now the only spelling.

### The defect the live run found, and the fix

**A colour override did not reach text already on screen.** Resetting colour 7 left every
line above it in the old palette — the exact two-conventions-in-one-buffer failure the font,
density and nick-colour settings all avoid by design, and the one this prompt walked into.

The cause is a real distinction rather than an oversight. An indexed colour goes into the
storage as an *appearance-resolving* `NSColor`, so switching between the light and dark
tables needs no pass over the buffer at all — the colours re-read themselves. That made it
look as though overrides came free with it. They do not: retuning what index 4 *means*
changes the value, not the appearance, and a colour already resolved into the storage cannot
know.

So there is now a third recorded attribute beside `InlineTraits` and `NickColumn`:
`InlineColours`, carrying the foreground and background *indices* and the `^R` flag, with
`MessageLogController.applyInlineColours` re-resolving them on every restyle.
`Palette.resolved(_:)` is the one place the reverse-video rule lives, so the renderer
drawing a line for the first time and the restyle redrawing it afterwards cannot disagree.
**Hex colours record nothing and are never touched**, which is §5's rule — `^D` names an
exact value and second-guessing it would overrule the one thing the sender was explicit
about.

The regression test was checked the only way worth checking one: by disabling the fix and
watching it fail, then restoring it.

### The other defect: literal asterisks

The Density caption rendered as `**Density is line height, not size.**`, asterisks and all.
These captions are built by concatenating string literals, which makes them a `String`
rather than a `LocalizedStringKey`, so SwiftUI draws markdown verbatim. Worth writing down
because the surrounding captions all use backticks the same way and always have — the
existing ones are consistent and this one was new.

### Deliberately not built

**§15.3's "Force monospaced grid" toggle**, which was in this item and is now stage 4's
item 44a. "Clamp everything, emoji included, to one cell" means owning glyph advancement,
and TextKit 1 exposes no supported per-glyph advance — the honest implementation measures
each wide grapheme against the cell width and applies compensating `.kern` so the grid holds
while the glyph overdraws, which is what a terminal does and is a layout subsystem rather
than a checkbox. Stripping VS16 instead would fix §15.3's six-character overlap set
(`☺ ☻ ♠ ♣ ♥ ♦`) and nothing else, under a label promising everything. It moved to stage 4
rather than staying in stage 2 so that it sits beside the text-pipeline benchmark it needs,
and so that it is scheduled somewhere real rather than left as an unattached item.

### `Scripts/run-app.sh`, because the wrong binary has now been launched four times

The live run opened the *previous* prompt's build and showed the old settings form.
`DerivedData` is keyed on the project path, so every worktree gets its own folder and a
hard-coded path launches whichever checkout built there last. `BUILD-LOG.md` records this
three times already, twice with a "defect" that had been fixed in the source being read at
the time.

So the path is asked for rather than written down: `xcodebuild -showBuildSettings` yields
`BUILT_PRODUCTS_DIR` and `FULL_PRODUCT_NAME`, and the script prints the binary, its build
time and the throwaway profile before launching. It also exports the three `XDG_*`
directories, which `CLAUDE.md` requires for a live run and which an inline assignment does
not achieve.

**And it got its own version of the same lesson immediately.** The first draft printed the
*bundle's* mtime, which does not move when a rebuild replaces the binary inside
`Contents/MacOS` — so it cheerfully reported 17:40 for a binary written at 17:51, which is
the same lie as a hard-coded path told more convincingly. It stats the executable now.

### The live run, against Libera in `##caravan-p10`

Seeded `caravan.conf` by hand with two comment styles, blank lines, an unknown key and a
`chat.colour.7 = 123456` the app had never written.

- The tabs drew, and `chat.font-size = 15` and the identity fields were read from the file.
- **The hand-added override was applied to real text**: a peer's `^C07SEVEN` arrived navy
  rather than mIRC's orange.
- Resetting colour 7 from the swatch's context menu turned `SEVEN` orange **in the line
  already on screen** — after the fix; before it, nothing happened, which is how the defect
  was found.
- Comfortable density visibly opened the lines with the glyphs unchanged, and the colours
  survived the restyle.
- **⌘+, ⌘− and ⌥⌘0 all fired live**: 100% → 121% → 110% → 100%, with Actual Size disabling
  itself at 100%. None was swallowed by a system binding, which is the check this stage has
  failed twice before.
- The Connect tab listed both seeded certificates in host order; Forget removed the row and
  the line from `known_hosts`.
- **The hand-edited file survived all of it.** Both comments, the blank lines and
  `something.unknown = must be kept verbatim` are still there, `chat.colour.7` is gone
  because it was reset, and the new keys were appended.

**Not verified live: being asked again after forgetting a certificate.** That needs a server
whose certificate the system rejects; the file and the list were both confirmed, and
`TrustTests` already covers the prompt itself against a real self-signed handshake.

## Stage 2, prompt 11 — The Dashboard and the server list

**Commit:** see PR  **Date:** 2026-08-07

The app's front door: a server list you keep, a Dashboard canvas to keep it on, and the
stable network name everything durable has been waiting for.

### The decision this prompt existed to make

**A network's stable, user-facing name is a slug on its server-list entry.** `PLAN.md`'s
longest-standing open question, blocking since stage 1, and now closed. Neither existing
candidate served: `ConnectionViewModel.id` is a fresh `UUID` per launch, so nothing written
down survives a restart, and `displayName` comes from `ISUPPORT NETWORK=`, which the
*server* owns — a name your bindings hang off must not be something a remote operator can
rewrite. So it belongs to the entry, and therefore to the user.

**Lower-case `[a-z0-9_-]`, and the two exclusions are the interesting part.** No slash,
because `libera/#swift` is the addressing form item 34a specifies and a name containing one
could not be told from a name plus a buffer. **No dot**, which is less obvious: both key
families put the name in the *middle* of a dotted key — `order.libera.channels` — so a name
with a dot in it makes that key ambiguous to parse. Constraining the name is much cheaper
than quoting the key. Lower case only, so two entries cannot differ by case alone and leave
the user guessing which of `Libera` and `libera` their binding meant.

Derived on creation from the host (`irc.libera.chat` → `libera`, dropping a leading
`irc`/`chat`/`www` and then the public suffix) or from the bouncer network id, which is
already the right word. Suffixed `-2` on collision rather than refused: adding a second
Libera account should not make you invent a word for it before you can connect.

### The list lives in its own file

`$XDG_CONFIG_HOME/caravan/servers.conf`, with the same `ConfigFile` machinery — write
through on change, rewrite only the lines you own, survive being hand edited — but not the
same file as `caravan.conf`. Ten entries of thirteen fields would bury the handful of
scalars a user actually opens the settings file to change. **The precedent is
`known_hosts`**, which is separate for exactly this reason: a list of records has a
different shape and a different lifecycle from a page of settings. Keys are
`<name>.<field>`, which parses on the first dot, and is why the name may not contain one.

Only what differs from a default is written, so a hand-written entry is one line —
`libera.host = irc.libera.chat` — and everything else takes its default.

### Migration, which is the part that could have lost data

`binding.N` and `order.<network>.{channels,queries}` were both written against
`host:port[bouncer]`. `NetworkKeyMigration` rewrites them on launch, matching each old key
to the entry with that host, port and bouncer id — and **where nothing matches, it creates
the entry**. Somebody who bound ⌘3 last week finds ⌘3 working this week and the network it
names sitting in their list. Dropping a key because its format changed is not a migration.

Idempotent by construction rather than by a flag: a `ServerEntry` name can hold neither a
colon nor a bracket, so a migrated key no longer parses as the old form and the second
launch has nothing to match.

**`server.host` in `caravan.conf` becomes the first entry** when the list is empty. One
rule covering two things: it migrates a real user, who has exactly one server they care
about and it is the one the Connect sheet last used; and it keeps the acceptance-run
harness working, which has seeded that key since prompt 3 and would otherwise have died
with the sheet.

### `ConnectSheet` is deleted

Not deprecated — the file is gone, per §13's "the two should not both exist". `TrustSheet`
lived in it and survived, in a file of its own: a certificate question genuinely is modal,
because the TLS handshake is held open waiting for the answer. The two layout tests that
hosted the sheet now host `ServerEditor`, which is the surface that inherited its job and
the same kind of `Form` — so they still guard prompt 2's row-collapse defect.

The width assertion did not survive the move, and the reason is worth recording: the sheet
declared `.frame(width: 460)`, so its fitting width was a promise. The editor lives in a
resizable split pane, where fitting width is a *preference* — 744pt, meaning "I would like
to be wider", not "I overflow". Asserting on it would have tested the paragraph lengths.
What replaced it asserts no leaf draws past the pane, which is the actual failure.

### Five defects, all found by the live run

The most any acceptance run in this project has caught, and four of them are one shape:
**state that exists in more than one copy.**

1. **Autojoin and perform never ran.** `waitUntilRegistered` treated `.disconnected` as an
   ending, but `.notStarted` is the *initial* state — the wait began before dialling had
   started, saw a `.disconnected`, and gave up a millisecond in. `DisconnectReason.isNotStarted`
   now draws the distinction, and it is the sort of bug no unit test written by the same
   person would have caught, because the same wrong assumption would be in both.
2. **The tree showed the server's word, not the user's.** `Libera.Chat` rather than
   `libera`. Two entries for the same network — which is precisely why the slug exists —
   would have drawn two identical rows. `ConnectionViewModel.treeName` prefers the user's
   name; `displayName` stays as the server's own word for the prose that wants it.
3. **First run did not land on the Dashboard**, contradicting §13's "it is what you land
   on with no connections open". It showed a "Not connected" placeholder with a button that
   opened the Dashboard, which is a click spent on nothing.
4. **Return in the editor connected instead of committing a rename.** The Connect button
   carried `.keyboardShortcut(.defaultAction)`, and a form full of text fields must not
   have a default button.
5. **A rename left a duplicate entry.** This one is the good one. Renaming `libera` to `lc`
   wrote `lc.*` correctly and left every `libera.*` key behind. The cause: when the entry is
   renamed the list's selection still names the old one, the detail pane falls back to "no
   server selected", and the editor is torn down — during which SwiftUI writes its fields'
   last values back through their bindings, under the old name, **resurrecting the entry the
   rename had just moved away from.** Two fixes, because either alone is a coincidence:
   `ServerEditor.update` refuses to write an entry the list no longer holds, and the rename
   carries the selection with it.

And a sixth, found while confirming the fifth: **a rename reached the files but not the
three in-memory copies.** `ConnectionViewModel.networkName`, `BufferBindings.slots` and
`BufferOrder`'s dictionaries are all parsed at launch, so after a rename ⌘3 lost its badge
and reported the network as not open while it sat in the tree. `AppModel.renameServer` is
now the one entry point and updates all three; `ServerList.rename` alone is not enough, and
its documentation says so.

**One test nearly passed against the bug it was written for.** The first version seeded
`binding.3` by writing the key to the config file — but `BufferBindings` parses that file
once at launch, so the key was invisible to it and the assertion read `nil`. Binding through
the live API is what makes the test exercise the in-memory copy at all.

### The live run, against Libera

Seeded a hand-written `servers.conf` with two entries and a `caravan.conf` carrying an
old-format `binding.3 = irc.libera.chat:6697/##caravan-p11`.

- **The migration ran on launch** and rewrote both the binding and the order key onto
  `libera`, matching the hand-written entry rather than creating a duplicate. Comments
  survived.
- Both entries appeared under their group heading, read from a file the app had never
  written.
- Connecting autojoined `##caravan-p11`, and the tree row read **`libera`** — the user's
  name, not `Libera.Chat`.
- ⌘3 opened the channel: an old-format binding, migrated, still working.
- Renaming to `lc` moved `binding.3` and the entry, left **no** `libera.*` key behind, and
  the connection, the binding and the tree all followed.

**Not distinguishable live: the perform line.** `/mode caravan-p11 +i` is invisible against
Libera's own `+Ziw`. Autojoin runs after perform in the same function, so the path executed;
the scripted-server test asserts the ordering precisely, which is the better evidence.

**Not driven live: double-clicking a list row to connect.** The synthesised double-click
selects the row without firing `onTapGesture(count: 2)` reliably inside a `Section`; the
Connect button and the context menu were used instead. Worth a human's hand before anyone
relies on it.

## Stage 2 — splitting prompt 13, and why 14 and 15 stayed whole

**Commit:** see PR  **Date:** 2026-08-08

Prompt 11 shipped with six defects found in one acceptance run, which is a scope signal as
much as a diligence one. This is the follow-up: reading the remaining two-item prompts
before starting them rather than after.

### Prompt 13 splits; the pairing argument did not hold

It carried two `PLAN.md` items — Highlights & notifications (21) and Ignore list (22) — on
the grounds that they are "the same matching machinery pointed in opposite directions".
Reading it against the code, that is not quite true. Highlights match *message text*
against keywords and patterns. Ignores match *senders* against `nick!user@host` masks, and
`IRCMask` already exists for that. The two matchers share neither their input nor their
implementation.

What they do share is one seam: `ConnectionViewModel.append(_:)`, where a line becomes a
buffer line, an activity state and a URL-catcher entry. That is a few lines of overlap, not
a prompt's worth of common ground — and it is exactly the kind of thin-sounding-thick
justification that produced an oversized prompt 11.

Each half is a prompt on its own terms. **13a** is masks, level flags, durations, a
command, a menu item and three suppression points. **13b** is keyword and regex lists,
macOS notifications, a Dock badge, a menu-bar item, per-event sounds and a Sounds tab —
three delivery surfaces, each with its own permission and lifecycle story.

**13a goes first, and the ordering is the substantive part of the split.** An ignored line
must never reach the highlight rules. Whichever half lands second inherits the other's
suppression points: highlights first means ignore acquires a fourth thing to suppress;
ignore first means the highlight rules simply never see a suppressed line. One order costs
nothing, the other costs a note that nobody reads until it is wrong.

### 14 and 15 were examined and left whole

Recorded because "we looked" is worth as much as "we split", and stops the question being
asked again.

**14 (Notify list · Away system)** is the same two-item shape as 13 and stays together. The
halves are much smaller — `MONITOR` with an `ISON` fallback and a window; a command, an
idle timer and a log — and the shared seam is real: both read the presence capabilities
`NegotiatedCapabilities` already tracks, and both have to tell "absent" from "this server
does not say", which is the trap prompt 3's note names.

**15 (Channel list)** is one item and one surface. The thing that makes it sound large is
that Libera answers `/list` with about 22,000 channels — but that is not a separable second
prompt, because a list built without it in mind is not a list to make fast later, it is a
list to write again.

### Lettered, not renumbered — and the reason is the append-only log

`13a`/`13b` rather than making the split into 13 and 14 and shifting everything after it.

Renumbering would have been mechanically simpler, but **`BUILD-LOG.md` is append-only and
holds five references to "prompt 13" through "prompt 17"** written by prompts 8, 9 and 10.
Renumbering makes every one of them quietly wrong, in a file that cannot be corrected. A
silently wrong document is the exact failure this project's discipline exists to prevent,
and lettering keeps all five true: "the matching machinery is prompt 13's, with the ignore
list" resolves to 13a without ambiguity.

It is also the convention `PLAN.md` already uses for split items — 18a, 22a, 34a, 44a — and
`check-docs.sh`'s item rule has matched `[0-9]+[a-z]*` since before this.

### The check that had to change, and the bug it would have had

**`check-docs.sh` compared a prompt *number* to a *count*.** The staleness rule reads
`**Status:** N/18 complete` — a count of finished prompts — and flagged a carry-forward note
whose prompt number was `<= N`. Those were the same thing only because prompts were numbered
1…17 with nothing split.

With 13a and 13b in the queue they diverge: awk's `$3 + 0` reads both as `13`, so finishing
13a (count 13) would have flagged **13b's** notes as stale — a false failure on the very next
prompt. Counting headings in order and comparing position instead compares like with like,
works whether or not anything is split, and names the offender by its label rather than by a
number that may now be shared.

Verified by setting the status to 13 and watching it report `12 13a` and *not* 13b, which is
the correct answer and the one the old rule could not have given.

Two smaller edits followed: the README table's row regex gained `[a-z]*`, and the total went
to 18.

### Learned

**`git checkout -- <file>` to undo a one-line experiment reverts the whole file.** Used to
restore a status line after testing the staleness rule, it took the entire prompt-13 split
with it — about eighty lines, rewritten. The undo wanted was to the *line*, and the tool
operates on paths. Cheap here because the content was still in the session; it would not be
cheap twice.

---

## Stage 2, prompt 12 — Logging

Plain-text chat logs, a reload of the tail when a window opens, a viewer, a Logging tab,
and the de-duplication that stops a bouncer's backfill arriving as a second copy of what
is already on screen. `ChatLog`, `ReplayIndex`, `LoggedLine`, `LogViewerSheet` and
`AppDirectories` are new; `ConnectionViewModel.append(_:)` is where they meet.

### The decision the rest of the prompt hangs off: what keys a line

**A log line carries `[yyyy-MM-dd HH:mm:ss]`, not mIRC's `[HH:mm:ss]`.** mIRC leaves the
date to a `Session Start:` banner at the top of the file. Reconciling a logged line against
a replayed one means comparing a *moment*, and a date recoverable only by scanning backwards
for the nearest banner is not a moment a line carries — it is a moment the file carries, and
only if the banner is intact. Everything else is mIRC's: the stock `LineFormatTable.mIRC`
sentences, codes stripped, one file per buffer, `grep`-able.

The consequence is that the fallback key — `(stamp to the second, nick, text)` — is strong
enough to use on its own. A false positive needs the same person to say the same words in the
same second, which is not a false positive; it is the duplicate being removed. `msgid` is
used where both sides have one and decides *against* a match too: two lines that each carry
an id and disagree are two lines.

**Rejected: a sidecar file holding the `msgid` per log line.** It would have made the key
exact everywhere. It would also have meant the log was no longer the plain text this feature
promises — two files that can disagree, one of which is unreadable, and a user who edits or
deletes one of them silently breaks the other. Worth revisiting only if the triple is ever
observed producing a wrong answer in practice.

### Two carry-forward notes were answered "no", which is the substantive result

Prompt 4 left two, and both were built into the prompt as *questions* rather than
instructions. Recording the measurements, because "we decided not to" is worth as much as
"we did", and both will otherwise be proposed again.

**No envelope over `IRCEvent`, and no `tags` on the replayed cases.** The note reasoned that
"a local log holds joins, parts and topic changes too, and reconciling those against a replay
needs their `time` and `msgid` as much as a message's". The premise is false in the direction
that matters: `chathistory` is *message* history. A bouncer does not replay joins, parts or
topic changes, so a logged join has nothing to collide with, and keying one would be
machinery built for traffic that never arrives. `ConnectionViewModel.replayKey(for:at:)` is
five lines and matches on `.message` alone; `LoggedLine` parses the three speaker shapes
(`<nick>`, `* nick`, `-nick-`) and returns no key for `*** Joins:`. The envelope was the
larger change and the note guessed it was "probably the right one" — it was not needed at
all, and an envelope touching every consumer for a benefit nothing uses is the expensive
kind of wrong.

**No `CHATHISTORY BEFORE`/`AFTER` against the newest logged line.** The note wanted the
request narrowed so there was less overlap to de-duplicate. But `LATEST <limit>` is bounded
by the limit, and `AFTER <the newest line in a log last written to a month ago>` is bounded
by nothing the client knows before the reply arrives. The overlap `LATEST` produces is at
most `chatHistoryLimit` lines and is exactly what the index absorbs. Narrowing the request to
avoid a bounded cost, by making an unbounded one, is the wrong trade.
`IRCSession.requestHistory(for:)` carries the reasoning at the call site.

### Where the suppression goes, and why it is one `continue`

A de-duplicated line must not appear, must not raise the activity state, must not reach the
URL catcher and must not be written to the log. Four consumers, all in the same loop in
`append(_:)`. They are guarded by a single `continue` before any of them rather than four
conditions, so a fifth consumer cannot be added and missed — which is precisely the failure
prompt 13a's note now warns about for ignores, since ignore inherits this loop.

`noteConversation` sits outside the loop and needed a `shown` flag: a message suppressed in
every buffer must not update a query's header band either.

### Rendering the log without paying for it twice

The log is *not* the displayed line with its attributes discarded — a log whose shape moved
when somebody previewed a timestamp format would be a log nothing could read back. It is
rendered canonically: `LineRenderer.plainLine(for:context:)` reuses the private `describe`
that already turns an event into a kind and its fields, then expands the same template with
the canonical stamp.

**The performance trap this avoids is `NSDataDetector`.** `render` runs a link scan over
every line, and it is the most expensive step on the ingest path. A naive log implementation
that rendered a second `AttributedString` and stringified it would have doubled it for every
message. `plainLine` builds no attributes and runs no detector.

`ChatLog.stamp` composes from `DateComponents` rather than using a `DateFormatter`: it runs
once per line written and once per line read back, `DateFormatter` is not `Sendable` so it
would have needed the lock-guarded cache `LineRenderer` keeps, and the format is fixed.
Gregorian is named explicitly — `Calendar.autoupdatingCurrent` would stamp a
Japanese-calendar user's log in the year 2569.

### Smaller decisions

**Logging is on by default for channels and private messages, off for the status window.**
mIRC shipped with it off, which means the log you want is the one you did not have. This is a
decision made on the user's behalf about writing what they say to disk, so the Logging tab
says plainly what is written and where, and there is a Reveal button. The status window is a
transcript of the client talking to itself, rewritten on every connect.

**Reload happens on buffer *creation*, not on `JOIN`.** The item says "reload last N lines on
join", and a reconnect is the case it names — but a buffer survives a reconnect, so replaying
on every `JOIN` would prepend the log to a window that already holds the conversation.
Creation is the moment there is genuinely nothing there.

**Replayed lines are dimmed and carry no banner.** A new `LineKind.logReplay` with a bare
`$text` template: the line was already rendered, stamp and all, by whatever wrote it, and
re-expanding it would be a second guess at what the file already answers. The boundary where
dimming stops is the signal.

**Own messages are remembered at the neighbouring seconds too.** Our clock stamps a locally
echoed line and the server stamps its replay of it; they agree to a fraction of a second and
disagree about *which* second roughly half the time. Two extra keys at the one site where a
local clock invents a stamp. Only reachable on a server with `chathistory` but not
`echo-message` — with `echo-message` there is no local echo to disagree with.

**Buffer names are percent-escaped narrowly.** `/`, `:`, `%` and the control range, plus a
leading `.`. Nicks legitimately contain `[ ] \ { } | ^` and escaping those would make a
directory the app invites people to open unreadable. `%` first, or `#a/b` and `#a%2Fb` would
be one file.

**`AppDirectories` was extracted at the third caller.** `ConfigFile` and `KnownHosts` each
carried their own copy of the XDG dance; the log would have been the third. Both keep their
documented `directory` property and now compute it from one place.

### Measured

`ReplayIndex` is a linear scan over a 500-entry array. A replay burst of 50 lines is 25,000
comparisons of a small struct, which is nothing at human message rates; a dictionary would
have needed two indices into one multiset to keep `msgid` and the triple pointing at the same
entry. Revisit if a buffer ever needs a five-figure index, which it will not.

The tail read is bounded to the last 1 MiB rather than reading the file. Two hundred
characters a line puts five thousand lines inside that window, far past any reload count the
form offers, and a partial first line is discarded when the window did not start at the
beginning of the file. `ChatLogFileTests` writes past the window and asserts exactly that.

### Learned

**The negative control was worth the two minutes.** All ten end-to-end tests passed the first
time they ran, which is not usually good news. Disabling the `consume` guard produced six
failures across three tests with the exact duplicate counts — 2 where 1 was expected, 3 where
2 was — which is what proves they were testing de-duplication rather than agreeing with it.
The `suppressionIsTotal` test only started asserting the activity state after that pass;
before it, it checked the catcher and the line count and would have missed a regression in
the third seam.

**A barrier has to land somewhere other than the buffer under test.** That same test waits
for a marker line before asserting "nothing arrived here" — and the first version sent the
marker to the channel it was asserting on, so the marker itself raised the activity the
assertion was about. It now sends a server `NOTICE`, which lands in the status window.

### The live run, and the defect it found in somebody else's code

Against Libera, under its own `XDG_CONFIG_HOME`, with a scripted second client as the
counterparty. What it confirmed: the file lands at
`$XDG_DATA_HOME/caravan/logs/libera/#caravan-log-test.log`; the sentences are mIRC's; every
line carries `[2026-08-07 23:34:37]`; the seven lines the peer sent carrying every
formatting code arrived in the file stripped, with no control byte anywhere. Quitting and
relaunching opened the channel with eleven dimmed lines above the live `*** Joins:` — and
the two are visibly different, because the reloaded lines carry the canonical stamp and the
live ones carry the user's `[HH:mm:ss]`. The reload did not re-write those eleven lines to
the file, which is the check that the replay path stays out of the writer. The Logging tab
came up with the right three defaults, and the viewer scanned the directory, un-escaped the
names, loaded the transcript and filtered it.

**`connectStartupServers()` had no caller.** Prompt 11 wrote the method, drew the toggle,
wrote `connect-on-startup` into `servers.conf` and shipped the setting doing nothing. Found
here in the first thirty seconds: a hand-written `servers.conf` with the flag set produced a
Dashboard that just sat there, and `rg connectStartupServers Sources App Tests` returned one
line — the definition. Fixed with `.task { await model.connectStartupServers() }` on
`RootView`, and pinned by `ServerConnectingTests.startupServersConnect`, which asserts that
the marked entry is dialled and the unmarked one is not.

The method could not have been caught by a test, because the missing thing was a *caller* in
a SwiftUI `body` and nothing in a `body` is reachable from `swift test`. It could only have
been caught by launching the app — which is the whole argument for the live-run rule, making
this the fourth defect it has caught that every unit test passed.

**Not verified live:** de-duplication against a real bouncer, because there is still no soju
to point at — `PLAN.md`'s "Where does a soju come from?" has blocked that acceptance since
stage 1, and it was driven against a scripted server instead. And our own outbound line
reaching the log: synthetic keystrokes would not land in the chat input, though they drove
the quick switcher, the tab picker and the viewer's filter perfectly well. That path has an
end-to-end test through the real `send()`.

**Worth writing down about driving the app:** `System Events`'s `click at {x, y}` does not
actuate a SwiftUI `List` row. It reports the element it would have hit — which reads exactly
like success — and changes nothing. Keyboard works: Tab into the list and arrow down, or
⌘K and type. A future acceptance run should reach for the keyboard first rather than
spending four screenshots discovering this again.

---

## Stage 2, prompt 13a — What deserves none

The ignore list: wildcard masks, mIRC's level letters, temporary ignores, `/ignore`, a menu
item and a list in Options. `IgnoreLevel` is new in `IRCProtocol`; `IgnoreList` and
`IgnoreEntry` in `CaravanUI`; the suppression is one function in `ConnectionViewModel`.

### The invariant, which matters more than the feature

**An ignore hides lines. It never changes state.** An ignored person still joins, still
appears in the nick list, still holds their prefix, and still disappears when they quit.
`IRCEvent.channelChanged(_:)` carries the roster and is not in the ignorable set at all —
what gets suppressed is the *rendering* of an event, never the event.

This is worth stating as loudly as it is stated in the source because the tempting
implementation is the wrong one. Dropping the event in the pump would be fewer lines and
would produce a client whose member list silently disagrees with the server, which is a far
worse bug than the noise being hidden. `stateIsNeverSuppressed` is the test that pins it:
ignore bob, watch his join line vanish, and assert he is in `channel.members` anyway — and
then that he leaves it when he quits, with that line hidden too.

### One `return`, above five consumers

`append(_:)` now feeds the line, the activity state, the URL catcher, the chat log and the
query header band. Prompt 12 left its de-duplication as a single `continue` above four of
them precisely so a fifth could not be added and missed; this goes above *that*, as an early
`return`, and picks up the fifth. A line nobody was going to be shown should not consume a
replay key either.

`withIgnoresApplied(_:)` returns the event, a rewritten event, or `nil` — three outcomes
rather than a boolean, because `k` is not a suppression.

### The `k` problem, and why it is not a boolean

Six of the seven levels hide a line. `k` keeps it and takes the formatting off, which is
what you want for somebody whose every word is a different colour but who is still worth
reading. So the test cannot answer yes-or-no.

It is implemented by rewriting the event's text through `IRCFormatting.stripping` before
rendering, rather than by telling the renderer about the ignore list. That keeps
`LineRenderer` a pure function of its input, which is what makes a rendered line testable
without an ignore list in scope — and it is the same reasoning that kept the log's plain
renderer out of the display path in prompt 12.

### `m` is ours, and this is the entry that says so

**Chose:** `m` means joins, parts, quits and nick changes.

`PLAN.md` and the prompt both record mIRC's flag set as `-pcntikm`. Five of those letters
are mIRC's and unambiguous — `p c n t i` — and `k` is mIRC's control-codes flag. Nothing in
this repository records what `m` meant, and reconstructing it from memory of a 1998 help
file is exactly the kind of confident guess that ends up in a doc comment as fact.

**Rejected:** leaving it out, which would have meant shipping six of a seven-letter set
`PLAN.md` promises; and guessing at mIRC's meaning and asserting it.

**Chose instead** to define it, use it for the ignore people actually ask for — the noise
somebody makes without saying anything, from a client that cannot hold a connection — and
say in `IgnoreLevel`'s own doc comment that Caravan defined it. **What would justify
revisiting:** anybody producing mIRC's actual definition of the letter. If it conflicts,
mIRC wins and this is a rename.

### Smaller decisions

**A bare nick becomes `nick!*@*`, not `*!*@host`.** The opposite of what
`ConnectionViewModel.banMask(for:in:)` does with identical-looking input, and both are right:
a ban wants to survive its target typing `/nick`, and an ignore wants not to catch the forty
other people behind one bouncer's host.

**Yes, an ignore suppresses the log.** Prompt 12's note asked the question rather than
answering it. mIRC logs what it ignores; we do not. A line you were never shown, written to
disk where you will never think to look for it, is the worst of both — and the log is the one
consumer whose mistake is permanent. Said on the Options surface, not only here.

**Never yourself, and never a server.** A `*!*@*` ignore is a thing people set, and without
the first guard it silently eats your own echo — a client appearing to drop what you type.
Without the second it takes out the MOTD. Both have a test.

**A kick is not ignorable**, and neither is a topic change. Being thrown out of a channel is
news about *you*; a client that hid it because you had ignored the operator would leave you
wondering why the window went quiet.

**The wire trace is never filtered.** The `.raw` branch of `append(_:)` returns before the
ignore test. Somebody working out why they cannot see a person has to be able to see them,
and an ignore is a display filter rather than a censor of diagnostics.

**Levels combine across matching entries.** `bob!*@*` for his notices and `*!*@his.host` for
his CTCPs means both, rather than whichever was typed first — the only reading where the
answer does not depend on entry order.

**A hit on `add` replaces rather than appends.** `/ignore -n bob` after `/ignore -p bob` is a
correction, not two entries whose combined effect nobody can predict.

### The storage format, which prompt 13b inherits

`ignore.<n> = <levels> <mask> [<expiry as epoch seconds>]` in `caravan.conf`. One key per
entry, one line each, the whole family rewritten and renumbered on every change.

**Prompt 11's `<name>.<field>` shape could not be used**, and the reason generalises: it
parses on the first dot, and every useful mask has dots in it. Prompt 11 banned dots in
network names for exactly this reason, and a mask is not ours to ban them from. So this is
the second of the two precedents prompt 10's note offered — `chat.colour.N`'s one-key-per-
element — with a compact three-field value rather than a scalar.

Levels are written as `*` for everything, which is what reads best in a file; `pcntikm` says
nothing that `*` does not. Expiry is absolute rather than a remaining duration, so a `-u600`
set five minutes before you quit has five minutes left when you come back. A lapsed entry is
dropped at load and the file rewritten: a file full of expired ignores is a file that lies.

### Measured

Matching is a linear scan over the entries, folding under the connection's live casemapping,
with `IRCMask.matches` doing the glob. It runs once per event that has a sender. An ignore
list is single digits in practice and `IRCMask`'s matcher is already iterative-with-
backtracking rather than recursive, which is the part that would have mattered.

`sweep()` runs on every match rather than on a timer. A timer firing in a client nobody is
looking at is a wakeup for nothing, and the only moment an expiry has to be correct is the
moment somebody speaks.

### Learned

**Two placeholder tests were waiting for this prompt and both fired.** `ignoreIsDeferred`
asserted `/ignore` was *not* in `knownCommands`, and `queryHasNoMembershipItems` pinned the
exact menu for a conversation. Neither is a test of this feature; both are tests that the
previous prompt's deliberate omission was still deliberate. They cost nothing to write and
they are the reason nothing was silently forgotten between prompt 8 and here.

**The menu item ended up somewhere the note did not predict.** Prompt 9's note said Ignore
"belongs in the third group beside Kick and Ban". It does not: that group only exists in a
channel, and a conversation is exactly where you most want to stop hearing somebody. It is
its own group, last, always enabled — Kick and Ban ask the *server* for something and need a
prefix; ignoring somebody needs nobody's permission.

**The negative control caught a gap in the tests again.** Stubbing `withIgnoresApplied` to
return its input unchanged produced nine failures across six tests, covering all four
suppression seams. Worth the two minutes for the second prompt running.

### The live run

Against Libera, under its own `XDG_CONFIG_HOME`, with the ignore **written into
`caravan.conf` by hand** rather than typed — which is worth more than the typed route,
because it tests the file format against the person the format is for.

All five properties held. The peer's join, seven messages and quit reached neither the
channel window nor the log file; the nick list said "2 members" and listed `caravan-peer1`
throughout, which is the state invariant; the raw trace showed every suppressed line with
its `msgid` and `server-time` intact; the reloaded log tail above the live conversation
still showed what the peer said *before* the ignore existed, which is "never retroactive"
demonstrating itself; and the Options IRC tab listed `caravan-peer1!*@*` — "everything" —
with a Remove button.

**Not verified live:** the URL catcher staying empty, which needs the context menu, and the
typed `/ignore` — see below. Both have tests through the real path.

### Two harness defects, and the expensive one

**`run-caravan.sh` hard-coded a DerivedData hash, so the acceptance ran the *previous*
prompt's binary.** Xcode keys DerivedData on the project *path*, and every git worktree has
a different one — so the script written during prompt 12 kept launching prompt 12's build.
The symptom is the worst possible one: the feature under test appears not to work, in a way
indistinguishable from a real defect. Twenty minutes went into hunting a bug in `IgnoreList`
that was not there — a unit test reproducing the exact seeded config and the exact wire
source passed first time, which is what finally pointed at the binary rather than the code.

The script now resolves `BUILT_PRODUCTS_DIR` from `xcodebuild -showBuildSettings` and prints
the path and the build time before launching. Any acceptance run that cannot say which
binary it started is not an acceptance run.

**Synthetic keystrokes still will not reach the chat input**, confirmed a second time. They
drive the ⌘K switcher, the Options tab picker and a sheet's text field perfectly well, so
this is a property of the input field — an `NSTextView` subclass inside an
`NSViewRepresentable` — rather than of focus in general. Neither clicking it first nor
tabbing to it helps. That is why the ignore was seeded through the file, and why the typed
`/ignore` is covered by parser tests and by `applyIgnore` tests instead of live.

### One thing the live run found in this prompt's own code

**A mangled line survived from a failed edit**, and neither the compiler nor
`swift format lint` had anything to say about it:

    guard let event = event ?? Optional(event) ?? nil else { return }

A first attempt at stubbing the suppression for the negative control had matched and been
written after all. It is, by accident, *semantically correct* — right-associativity makes
the whole expression `IRCEvent?` and `nil` still propagates — which is exactly why nothing
caught it: every test passed, the negative control behaved, and the line reads like
something deliberate. Now `guard let event = withIgnoresApplied(event) else { return }`.

The lesson is about the tool, not the line: a scripted `str.replace` that finds no match
silently changes nothing, and one that finds an unintended match silently changes something.
The edit was verified by grepping for the *function name* afterwards, which was true either
way. Verify a scripted edit by reading the line it produced.

---

## Stage 2, prompt 13b — What deserves your attention

Highlights on your nick, your keywords and your own regular expressions; notifications, a
sound, a Dock badge and an optional menu-bar item behind them. `HighlightRules`, `Alerts`,
`AlertTrigger` and `MenuBarItem` are new; the decision hangs off the same
`ConnectionViewModel.append(_:)` seam as everything else in this stage.

### The filter that earns the prompt

Three conditions stand between a match and an interruption. Two are obvious — not your own
words, and not a window you are looking at. The third was not in any carry-forward note and
is the one that matters:

**A bouncer reattach replays `CHATHISTORY` through the ordinary message path, and those
lines survive prompt 12's de-duplication — correctly, because they are new to this client.**
Fifty of them carrying your nick is fifty notifications the moment you connect. The
de-duplicator cannot help: its whole job is to recognise what you have *already seen*, and
this is a backlog you have not.

So the rule is age. Anything whose `server-time` is older than `Alerts.staleAfter` — five
minutes — raises the buffer and stays silent. The buffer still goes pink, which is right:
the backlog genuinely is unread, it is merely not worth an interruption.

**Not a setting.** A user cannot be expected to have an opinion about it, and every value in
the sane range behaves identically for the case it exists for. The failure modes are
asymmetric in a way that picks the value: a notification five minutes late is mildly odd, and
fifty notifications for last night's conversation is what makes somebody switch the feature
off for good — after which it is worse than absent, because they believe it is working.

`replayIsSilent` is the test, and the negative control on it produced exactly the six
notifications the rule exists to prevent.

### A carry-forward note consumed by disagreeing with it

Prompt 12 suggested copying `ChatSettings.logs(_:)`'s per-buffer-kind split — channels,
queries, status — for the notification triggers. Rereading §18 says otherwise. "Highlights
and private messages, not every message, not highlights alone" is **one four-way choice**,
not three toggles that happen to add up to one, and `AlertTrigger`'s default is that sentence
verbatim.

The difference is not cosmetic. Three toggles can express "notify for channels but not
highlights", which is not a thing anybody means, and cannot express "every message" without a
fourth control. One enum has exactly the four states the design note describes.

The same note's other half — that `IgnoreLevel`'s `OptionSet` is the shape a highlight level
should copy — also did not hold, and for a reason worth recording: **an ignore has levels
because it filters kinds of traffic; a highlight is a predicate over text and either matches
or does not.** There is nothing to make a set of.

### `BufferActivity.caused` is `@MainActor` now

The table used to be a pure function of the event, our nick and one boolean. It now reads the
user's rules, which are observable state, so it is main-actor bound and so is
`BufferActivityTests`.

**Rejected: snapshotting the compiled rules into a `Sendable` box** to keep it pure.
`NSRegularExpression`'s `Sendable` conformance is not something to rely on, and the machinery
would exist for a property — testability off the main actor — that nothing needs. Every
caller was already on the main actor. The annotation is the honest description of what the
function became; the doc comment says so at the declaration.

### Smaller decisions

**A pattern that will not compile costs the pattern, not the launch.** These arrive from a
text field and from a hand-edited file. They are compiled once on load, the bad ones are kept
in the list and marked in the form, and they are written back to the file — silently deleting
somebody's typo on the next save is a worse answer than showing it to them as broken.

**One list, not two.** The first attempt kept `patterns` and `rejected` as separate arrays,
which produced a broken pattern that `remove` could not reach and a write order that depended
on which array it had landed in. `rejected` is now computed from the absence of a compiled
expression.

**Split on the first space only** — the one deliberate difference from `ignore.<n>`'s format,
because a keyword phrase may contain spaces where a mask never can. `word build failed` is
one rule about two words.

**The Dock badge counts highlights only** (§3: badges are additive for the highlight case),
and it is **derived, never counted**. A second counter incremented on a highlight and
decremented on a read drifts the first time a buffer is closed while unread. `allBuffers`
already knows; recomputing on the two events that can change it is cheap.

**The menu-bar item is off by default** and is an `NSStatusItem` rather than SwiftUI's
`MenuBarExtra` — the latter is a `Scene`, so it can only be created in the app target, where
nothing is testable, and toggling it needs a binding into the scene graph.

**Delivery refuses to fire outside an `.app`.** `Bundle.main.bundleURL.pathExtension == "app"`
guards it, so a test bundle cannot post a user notification or make a noise on somebody's
machine. Making that a property of the code rather than of test discipline is what stops it
happening the one time nobody remembered; `inertInTests` asserts the guard itself.

### Learned

**A local named for the method it calls produces an error three lines from the cause.**
`let isOwn = sender.nick.map { isOwn(nick: $0) }` shadows `isOwn(nick:)` inside its own
initialiser, and the compiler says "cannot call value of non-function type 'Bool'" pointing at
a different argument. Renamed to `isOurs`, with a comment, because the next person to write
this will write it the same way.

**Two of this prompt's tests were placeholders left by earlier ones**, and both fired: the
Options tab list, and `BufferActivity.mentions` moving to `HighlightRules.containsWord`. That
is three prompts running where the previous prompt's deliberate omission was pinned by an
assertion rather than by a note nobody rereads.

### The live run

Against Libera, with the highlight rules **written into `caravan.conf` by hand** — one
keyword, one pattern, and one deliberately broken pattern — and a scripted peer saying one
line per rule plus one that matches nothing plus a private message.

What held: both the channel and the query went pink, bold and badged in the tree, so a nick
mention, a keyword and a regular expression each reached the state they should; the
menu-bar item appeared with the count **2** beside its icon, which is the same derived
number the Dock badge uses; the IRC tab listed all three rules with `[unclosed` **in red
with a warning triangle** and a Remove button, which is the "kept and marked rather than
silently ignored" behaviour being visible rather than merely tested; and the Sounds tab came
up with "Highlights and private messages" selected, which is §18's sentence as a default.

The relaunch also confirmed the prompt 13a launcher fix: it printed the worktree, the
resolved binary and its build time before starting, and it was this prompt's build.

**The notification permission prompt fired on launch** and was left unanswered. Granting a
persistent system permission to a debug build is the user's call rather than something to do
to their machine mid-acceptance, so the notification *banner* and the *sound* are the two
things this run did not see. What that leaves unverified is thin — build a
`UNMutableNotificationContent`, call `add`, call `NSSound.play` — and the part that is not
thin, the decision about whether to interrupt at all, is `Alerts.shouldAlert` and is
exhaustively tested including a negative control.

**The Dock badge was not verified live either**, for a duller reason: the Dock is set to
auto-hide on this machine, and revealing it means either a synthetic mouse move that does not
work or changing somebody's Dock settings. `badgeCountsHighlights` drives the real
`NSApplication.shared.dockTile.badgeLabel` instead, and the menu-bar count observed live is
the same computation from the same `allBuffers` filter.

**Also learned about driving the app:** an added tab moves every other tab. The Options
picker is a segmented control and the coordinates recorded during prompt 12 pointed at
Display once Sounds existed, which cost two screenshots. Anything clicking a segmented
control should screenshot it first and read the positions off that, rather than reusing
coordinates from a previous prompt.

---

## Stage 2, prompt 14 — Presence

The notify list — `MONITOR` where the server has it, `ISON` polling where it does not — and
the away system: `/away` tracked from the server's own answer, auto-away on system idle, and
a summary of what happened while you were gone. `NotifyTracker` is new in `IRCSession`;
`NotifyList`, `AwayController` and `AwaySummary` in `CaravanUI`.

### The bug both halves share, which is why they are one prompt

**An unknown is not an absence.** A notify list with no reply yet is not a list of people who
are offline. An `ISON` still in flight is not everybody having signed off. `Member.isAway` is
`false` for "here" and for "this server does not offer `away-notify`". Every state in this
prompt is three-valued, and collapsing it to two is how a client comes to announce that all
your friends left the moment you connected.

`NotifyTracker` stores `[IRCNick: Bool]` and treats *absent* as its own answer, all the way
through: `isOnline(_:)` returns `Bool?`, and `takeBaseline()` puts a nick in neither the
online nor the offline half until something has said.

### The baseline, and the bug it prevents

Connecting produces one 730 naming everybody already online. Turning that into an event per
person is prompt 13b's `chathistory` bug wearing a different hat — a burst of announcements
for things that did not just happen — and this time it would fire on every reconnect.

So the first answer of a connection sets the baseline and emits **one** summary line; only
changes after it announce. `hasBaseline` is reset on disconnect, because answers from the
last connection say nothing about this one.

**The first implementation had this subtly wrong and a test caught it.** One 730 can carry a
dozen names, which arrive as a dozen events from a single message — and settling the baseline
inside the per-event loop meant the first name established it and the other eleven looked
like arrivals. `baselineIsNotABurst` reported `["carol"]` where it expected nothing. The
baseline is now taken in a `defer` after the whole message has been translated, which is the
honest unit: one message is one answer.

The negative control on the finished version produces `["bob", "carol"]` — both friends
announced as having just arrived — which is exactly the bug.

### Where the away log went

`PLAN.md` asks for "an away log capturing messages received while away". Most of that job is
now done by things that did not exist when the line was written: the unread rule marks where
you left, the activity states say which windows moved, prompt 12 logs every line and gives it
a viewer, and prompt 13b badges what was addressed to you.

What none of them give is the one-glance answer on return. So the away log is `AwaySummary` —
a count, rendered as one sentence — and the window is deferred on the item with that
reasoning. **This is the split conversation reaching a different verdict from prompt 13's**,
which is the point of having it each time: 13 found a second feature and split; 14 found a
third and shrank it.

**Also not built: the away nick.** Renaming somebody mid-session collides with `binding.N`,
`order.<name>.*` and every scripted reference to their nick — all of which key on identity
that a rename moves — and nobody has asked for it. Recorded on the item rather than dropped.

### Smaller decisions

**Auto-away is off by default**, because it speaks on the user's behalf: it tells a channel
full of people something about where you are. §19's "defaults taken without asking" covers
the ones nobody would mind, and this is not one.

**The idle clock is the system's**, via `CGEventSource.secondsSinceLastEventType` — away
means away from your desk, not away from this window, and somebody reading a backlog in
another app has not left. It needs no permission and it is one call, behind a closure so a
test of the timer is not a test of waiting five minutes.

**A typed `/away` is never undone by touching the keyboard.** `isAutoAway` distinguishes the
two, and a client that cancelled a deliberate away the moment the mouse moved would be
useless to anybody who sets one before a meeting.

**Our own away state comes from 305 and 306, not from having sent `AWAY`.** The request can
be ignored, and a client that believed itself would show the wrong thing on the servers that
do ignore it.

**The `MONITOR` limit is refused out loud.** Silently watching the first thirty of forty
names is worse than refusing, because the other ten are indistinguishable from offline —
which is the one way this feature can lie.

**A notify list is nicks, not masks.** `IgnoreList` matches `nick!user@host` because an
ignore is about a person however they connect; `MONITOR` and `ISON` both speak nicks and
neither takes a wildcard, so a mask here would be a promise the protocol cannot keep.

**An arriving friend has its own toggle**, `alert.notify`, rather than a case of
`AlertTrigger` — 13b's note asked for that decision to be made rather than defaulted, and
`AlertTrigger` describes what a *buffer* did.

### Measured

`ISON` polls every thirty seconds, in a loop that sleeps to a deadline in the shape
`IRCSession.idleMonitor()` already uses. A constant rather than a setting: it trades how
quickly an arrival is noticed against traffic generated while idle, and nobody has an opinion
until it is wrong in one direction.

The idle clock is consulted every fifteen seconds — the resolution, not the timeout. Finer
than any timeout worth setting, coarse enough that a client idle overnight is not why a
laptop's fan comes on.

### Learned

**`#expect` captures its expression in a closure, so a mutating call on a `var` struct will
not compile inside one.** `#expect(tracker.apply(...))` fails with "cannot use mutating member
on immutable value: '$0' is immutable", which does not obviously point at the macro. The call
goes on its own line and the result into a `let`; three tests needed it, and the fix also made
them read better, because the assertion then says what the value *means*.

**A sortedness assertion on `knownCommands` caught `/notify` inserted in the wrong place.**
Fourth prompt running where an exhaustive or invariant assertion from an earlier prompt did
the noticing rather than a note.

### The live run, and the three timing bugs it found

Against Libera, which advertises `MONITOR=100`, with the notify list written into
`caravan.conf` by hand. **Every defect this prompt shipped with was about *when* something
happened, and none of them was visible to a scripted server.**

**One: the watch list was never sent.** The app hands the list to a connection as soon as
one exists, which is before registration; `setNotifyList` guarded on `.connected`, returned,
and nothing retried. The first run produced no `MONITOR` at all.

**Two: 001 is too early to know whether the server has `MONITOR`.** Moving the issue point
to registration-complete looked right and was still wrong — `supportsMonitor` comes from 005,
which arrives *after* 001, so the `ISON` fallback won every time. The watch is now issued
once ISUPPORT has been applied, with end-of-MOTD as a backstop for a server that sends no
005, and a per-connection flag so a burst of 005 lines does not issue it three times.

**Three, and the interesting one: the baseline closed before the answer arrived.** The
baseline needs a terminator and `MONITOR +` has none — the 730s and 731s simply arrive. The
first attempt settled on a message boundary, which closed it on the very next line of the
MOTD. A five-second grace period looked generous and was not: **Libera took a little over six
seconds to answer**, so the reply landed just outside the window and the baseline became two
false arrivals — exactly the bug the baseline exists to prevent, produced by the mechanism
meant to prevent it.

The fix is to stop treating the deadline as the mechanism. `MONITOR +` is answered with a 730
or a 731 for *every* target, so `NotifyTracker.isComplete` is an exact terminator: the first
answer is finished when every watched nick is known. The grace is now thirty seconds and is
a backstop for what completeness cannot see — a server that silently drops a name it thinks
invalid, or one that never answers.

Which it did, twice, in this very run: `caravan-nobody-here` is nineteen characters and
Libera's `NICKLEN` is sixteen, so the server dropped it without a word and completeness could
never fire. Twenty minutes went into that before the acceptance config was fixed and a
comment left in it.

**What the run finally showed.** One line — `*** Notify — offline: caravan-peer3,
caravan-away9` — where the previous attempts showed two announcements; then, when a scripted
client took the watched nick, `730` followed by a single `*** caravan-peer3 is online`. Then
auto-away, from a config with `away.auto-minutes = 1`: `306` from the server and
`*** You are now marked as away`, which is the state coming from the server's answer rather
than from having sent the request.

**Not verified live: the `ISON` fallback**, because Libera has `MONITOR` and pointing at a
server without it was not worth a second acceptance — it has an end-to-end test against a
scripted server with `MONITOR` absent. Nor the return-from-away summary, which needs unread
buffers and keyboard input in the same breath.

**Worth keeping:** three timing bugs, three fixes, and a scripted server that could not have
found any of them, because a scripted server answers instantly and registers in one gulp. It
is the fifth prompt running where the live run earned its place.

---

## Stage 2, prompt 15 — Channel list

`/list` on a canvas: every channel the network will name, searchable by name and topic,
narrowed by size, sortable, and joined with a double-click or Return. `ChannelDirectory`,
`ChannelListing` and `ChannelListQuery` are new in `CaravanUI`, with `ChannelListCanvas`
over them; `IRCEvent` gains `.channelListEntry` and `.channelListEnd`.

### The feature started as a bug fix, and that is not a figure of speech

Before this prompt, `/list` sent `LIST` and nothing was typed for the reply — so every 322
arrived as `.numeric`, and `.numeric` is exactly the case the status window renders
verbatim. Asking a real network for a channel list appended thousands of lines to a
scrollback nobody wanted them in. So the first thing the prompt does is stop that: 322 and
323 became typed events chiefly *so that they are not drawn*, joining `.namesReply` and its
neighbours in the set `LineRenderer` renders as nothing.

That is also the shape of the test that guards it. `ChannelListBehaviourTests` drives five
hundred entries through a scripted server and asserts the status window's text contains
none of them — a regression invisible against four channels and unmissable against four
thousand.

### The performance is the design, not a pass over it afterwards

Rows accumulate into an array the view does not observe, and `listings` — the one property
the table reads — is assigned at most once per 250 ms plus once at 323. Without it, a list
is one observed mutation per channel, which is thousands of view invalidations while the
user is trying to type in the search field.

The coalescing is behaviour, so it is tested as behaviour rather than trusted: 22,000
`add(_:)` calls with a 60-second flush interval publish **once**, at `endCollecting()`.

Two smaller decisions in the same spirit, both about not doing per-row work per keystroke:
the topic is stripped of formatting codes and folded for searching **once, on arrival**, and
matching is plain case-insensitive substring rather than `FuzzyMatch`. Fuzzy is the quick
switcher's tool, where the corpus is forty buffers and the user is aiming at one they can
name; over thousands of topics it costs what this surface exists to avoid and answers
nonsense, because a short query's letters appear in scattered order in almost any sentence.

`handle(_:)` returns on these two events above everything else — above the case-mapping
note, the ignore test and a `RenderContext` that calls `Date()`. All of it is per-event work
multiplied by the size of the network to produce a line the renderer then declines to draw.

### Decision — one canvas with a picker, not one per network

A channel list belongs to a connection, so the obvious shape is a row per network. It is the
wrong trade: a channel list is *consulted*, not kept, and §12's tree would grow a permanent
row per network for an object opened twice a month. So there is one `SidebarItem.channelList`
pinned beside Settings & Debug, with the network chosen inside it — and, because it is the
one canvas that is about a network, it is also the one whose window subtitle names one.

Revisit if somebody genuinely browses two networks side by side; the canvas detaches, so
that case has an answer already.

### Decision — the filters are local, and `ELIST` stays unparsed

Many servers narrow `LIST` server-side, and Libera advertises `ELIST=CMNTU`. Filtering
locally anyway, for two reasons: refine-as-you-type must not be a network round trip, and a
second `LIST` is the most expensive thing a client can ask a server for. `ELIST` and
`SAFELIST` stay uninterpreted in `ServerCapabilities.rawTokens` until something needs them.
What a user types after `/list` is passed through untouched, so `/list >100 <500` still
works — that is their round trip to spend.

Revisit if a network appears whose full list is too large to hold, which is the only thing
this trade is actually betting against.

### Decision — Stop stops collecting, and says so

`LIST` has no cancel in the protocol. The button could not stop the server if it wanted to,
so it does not pretend: it stops *collecting*, drops what keeps arriving until 323, and its
help text says the server sends the rest regardless. The alternative — a Cancel that leaves
rows appearing for another ten seconds — is worse than no button.

Related, and found by thinking about the same ten seconds: `beginCollecting()` deliberately
leaves the previous rows on screen until the first new one arrives. Blanking the table for
the duration of a re-list loses whatever the user was reading, often the row they were about
to click.

### The live run found two defects, and both were invisible to the tests

**The canvas opened saying "connect to a network" from a connected client.** `showChannelList()`
resolved the network *after* setting the selection — and `activeConnection` reads the
selection, which had just become a canvas, which has no network. So it was `nil` every time
and Get List was greyed out on a live connection. The fix is to capture the network first;
the regression test asserts the awkward pair directly — `activeConnection == nil` and
`channelListConnection === connection` at the same moment.

**One stray line survived the silencing.** After an otherwise perfectly quiet `/list`, the
status window held a single `Channel Users  Name` — numeric 321, still an ordinary numeric
because the prompt had said nothing may depend on it. True, and beside the point: nothing
depends on it *and* nobody wants to read column headings for a table drawn elsewhere. It now
translates to no event at all. The prompt text was corrected in the same commit rather than
left describing a client that no longer exists.

### Measured, on Libera, first list on a fresh connection

- **3,902 channels in 5.0 s**, arriving in visible increments with the footer saying so.
  There is a two-second plateau at 2,211 in the middle of it that is the server's pacing,
  not the client's flush: our deadline is 250 ms.
- **~143 MB resident idle, ~231 MB with the list on screen.** About 23 KB a row against
  roughly 400 bytes of data — the rows are cheap and something per-row in the view is not.
  It does not matter at four thousand; the prompt was written for twenty-two, where it would
  be half a gigabyte. In `PLAN.md`'s **Still open**, with the caveat that every way of
  driving the app attaches an accessibility client, so the figure is an upper bound.
- **Keystroke to filtered result: no perceptible delay**, with a 200 ms debounce in front of
  it. Typing `zig` into the search field left `#zig`, `#vaxis` and `##vanshack`; unchecking
  Topics left `#zig` alone; a minimum of 100 dropped `#gdzig` at four members.

**The premise number was wrong, and in an interesting direction.** The prompt was written
around "Libera answers `/list` with about 22,000 channels", which is the MOTD's *channels
formed* — including every secret and single-occupant one. What `LIST` actually returns is
about 3,900. More surprising, each repeat returns fewer — 4,572, 3,180, 4,061, 3,683, 3,304,
1,988 across one session — every one of them terminated cleanly with 323, so the client
cannot tell a throttled list from a complete one. That means Refresh can hand back a smaller
list than it replaced with nothing visibly wrong. In **Still open**; it needs a second
network to know whether it is Libera's pacing or general.

The design does not change for the smaller number. A list built without the arrival cost in
mind is not a list to make fast later, and the coalescing is what let the search field stay
responsive at 2,000 rows a second.

### Not verified live

Column-header sorting and join-by-double-click: `System Events` cannot actuate a SwiftUI
table header or row — the same limitation prompt 12 recorded for `List` rows, which is now
three prompts old and worth remembering before spending screenshots on it again. Both have
the keyboard route as evidence instead: Return on a selected row joined `#zig` on Libera and
opened the window with its 652 members. The sort binding is `Table`'s own, exercised by
`recompute()` under test.

Multi-select join above five, which asks first, has no live evidence either — selecting six
rows needs a drag, and `System Events` cannot synthesise one.

---

## Decision — the channel list is a row under its network, not a pinned canvas

**Date:** 2026-08-09  **Affects:** `AppModel.SidebarItem`, `SidebarTree`, `ChannelListCanvas`,
GUI-DESIGN-NOTES §12

Prompt 15 shipped the channel list as a *third* pinned canvas at the bottom of the tree,
beside Settings & Debug, with a network picker inside it. The reasoning is in that prompt's
entry: a channel list is consulted rather than kept, so giving every network a permanent row
for something opened twice a month looked like the wrong trade against §12's tree.

**The user reversed it the moment they saw it: it should be the top item under the network.**
That is the better call, and the argument it beats is worth writing down rather than quietly
deleting, because it was wrong in an instructive way.

The mistake was treating "how often is it opened" as the question. The real one is **what is
it about**. A channel list is a property *of a network*, exactly as that network's channels
are — and everything else in the app that is about one network lives under it in the tree.
The bottom of the sidebar is for surfaces that belong to the *app*: the Dashboard above the
networks, Settings & Debug below them. A per-network object pinned among the app-wide ones
had to reintroduce the network as a picker inside the canvas, which is a control that exists
only to undo a placement mistake. Frequency of use argues about how much a row *costs*; it
cannot make a row belong somewhere it does not.

`SidebarItem.channelList` now carries a `UUID` like `.status` does, which is what makes two
networks two rows that select and highlight independently, and it encodes for window
restoration on the same path as a status row. The picker is gone; the canvas takes its
connection as a parameter and can no longer be constructed without one.

**A bug the earlier shape needed a fix for simply stopped existing.** Prompt 15's live run
found the canvas opening with "connect to a network" from a connected client, because
`showChannelList()` resolved the network *after* setting the selection and `activeConnection`
reads the selection — which had just become a canvas, and canvases had no network. The fix
was to capture the network first. With the row carrying its own network the question cannot
be asked at all: `activeConnection` now answers for a channel-list row, because it is a
canvas that genuinely is about a network. `selectedTarget` still returns `nil` for it —
there is nowhere to type — so "which network am I looking at" and "where would a line go"
have come apart, which they always should have.

Verified live on Libera: the row sits under `libera` above its channels, selecting it opens
that network's list with the header naming it, and Get List still returns the full list.

**What would justify revisiting it:** nothing about frequency. Only a case where the list
stops being about one network — a cross-network search, say — which would be a different
surface rather than a moved row.

---

## Stage 2, prompt 16 — Flood protection

Outbound pacing so a paste does not earn `Excess Flood`, inbound detection that ignores
somebody flooding you for a minute, and an `ERROR` before 001 treated as the refusal it
usually is. `SendPacer` is new in `IRCSession`, `FloodDetector` in `CaravanUI`.

### The two halves are opposite policies, and that is the design

Outbound is about lines *the user typed*: dropping one is unthinkable, so the answer is to
**delay**. Inbound is about lines a stranger sent: a message shown thirty seconds late is
worse than not shown, so the answer is to **drop**. Every decision below follows from which
side of that line it sits on.

### Decision — `CTCPThrottle` does not fold into the send queue

The carry-forward asked for this explicitly, and the answer is that they compose. The CTCP
bucket decides *whether to answer a stranger at all* and drops; the send queue decides *when
a line leaves* and never drops. Folding them forces one policy on both, and whichever half
lost would be wrong. The note's real worry — an auto-reply admitted by the bucket then
sitting behind a paste — is bounded at five replies and now visible, because a backlog says
so out loud.

**What would justify revisiting:** a third thing wanting to jump the queue. Two exemptions
with reasons are a rule; three are a priority system, and that is a different design.

### Decision — a queue with one drain, not a sleep inside `send`

`IRCSession` is an actor and actors are reentrant, so `await`ing a delay inside `send(_:)`
lets the next caller overtake the one sleeping — which reorders the user's own sentences.
Lines go into a FIFO and one task drains it. `PONG`/`PING`/`QUIT` bypass it always (a queued
`PONG` is a ping timeout: the limiter would cause the disconnect it exists to prevent), and
`NICK`/`USER`/`PASS`/`CAP`/`AUTHENTICATE` bypass it *only until registration* — `NICK` is a
registration line for one second and an ordinary command forever after, and a `/nick` loop is
a flood like any other.

### The threshold came from the live run, and the first one was unreachable

Twenty messages in ten seconds was the plan. Then the acceptance run measured what a real
network actually permits: **Libera throttles the sender**, and a scripted client trying to
push twenty-four lines as fast as it could got **fourteen through in five seconds** before
the server silenced it — `*** Message to <target> throttled due to flooding`, for a private
query *and* for a channel. A threshold no flood on the network can cross is a feature that
cannot fire. It is now **twelve in five seconds**, which is inside what the server permits
and is still nothing a person types.

Worth keeping for whoever tunes this next: on a well-run network the server is the first
line of defence and this is a backstop. It matters on networks without sender throttling,
and it is why the numbers live in the source with their reasoning rather than in a settings
pane — a slider would have been shipped at twenty and never questioned.

### The prompt 15 note was answered by making it inapplicable

That note asked the detector to consult `ChannelDirectory.isCollecting` so a `/list` of
twenty-two thousand lines could not auto-ignore the server. It does not, because it counts
messages **from people** — numerics are not messages, so a `LIST` reply, a large `NAMES` and
every `MOTD` are outside the mechanism rather than special-cased inside it. Consumed, and the
test asserts it directly.

The same reasoning covers a bouncer's replay, via a second property: counting is against the
line's **own timestamp**, the `server-time` that `Alerts.shouldAlert` already uses to tell
history from news. A hundred lines delivered in one second, stamped minutes apart, is a
hundred messages over an hour. No replay state was needed.

### Auto-ignore is a temporary ignore, not a second mechanism

Prompt 13a's `IgnoreEntry.expires` is exactly this feature, so a flood adds a timed entry to
the list the user can already see and edit — undoing one is something they already know how
to do. The mask is `nick!*@*` rather than the full source: somebody flooding and then cycling
their host is the ordinary case, and an ignore a reconnect defeats is not an ignore. On by
default under §19, because it is temporary, announced, visible and reversible.

### Two defects, both found live, neither findable in a test

**The zombie state.** Pointed at a server that refuses, the client showed the refusal
correctly and then sat saying "Registering…" for ever. `beginRegistration` awaits four sends;
the `ERROR` was handled *inside* those awaits, tore the attempt down and set `.disconnected`
— and then the function resumed and announced `.registering` over the top of it. Guarded on
the attempt still being live.

**It has an invariant test, not a reproducing one, and that is stated at the test.** Refusing
on connect, on `NICK` and on `CAP` were all tried against the scripted server and none
reproduces the interleaving: over loopback the inbound line is never processed inside those
awaits. `ScriptedIRCServer.greet(with:)` was added along the way — the only way to script a
server that refuses before the client has said a word — and is worth keeping regardless.

**The backlog notice lied by being accurate.** It said "Sending 6 lines a little at a time"
while thirteen were on their way, because callers enqueue one line at a time and the notice
fires the moment the queue passes the burst. The count is gone.

### Measured, on Libera

- **Outbound: the free burst, then one line every 2.00 s**, timed by a scripted witness in
  the channel: gaps of 1.99, 2.01, 2.00, 1.98 s. Thirteen lines took about ten seconds
  instead of arriving at once, and Libera sent us no throttle notice at all — which is the
  whole point of the exercise.
- **Inbound: twelve lines arrived and the thirteenth did not.** `*** caravan-fm16 is
  flooding — ignored for 60 seconds. See Options ▸ Ignore to undo it.`
- **`ERROR` before 001: one connection, no retry**, confirmed by the refusing server
  counting its accepts for forty seconds.

### Not verified live

That a paste *typed by a person* is paced: synthetic keystrokes still do not land in the chat
input (prompt 12's limitation, now three prompts old). The outbound burst was produced by a
`perform` list instead, which reaches `submit` by the same path a typed line does.

**Two things CI caught that a local `swift build` cannot.** The guard above read
`guard connection != nil` — but `beginRegistration` opens with `guard let connection`, which
shadows the property with a non-optional local, so it asked whether a value already in hand
was nil. It compiled, it did nothing, and only `-Xswiftc -warnings-as-errors` said so. `self.`
is load-bearing there. **Run the CI build, not the convenient one**, when a change is inside a
function with a shadowing `guard let`.

Also fixed in passing: `CapabilityBehaviourTests.withoutTheTag` asserted that a freshly
stamped line was *not* `:51`, which fails once a minute — during the fifty-first second. It
now asserts the stamp is the current second, plus a second either side.

---

## Stage 2, prompt 17 — Buffer utilities

⌘F over the scrollback with AppKit's find bar, `Find in Log…` beside it, and a copy that
gives plain text unless asked otherwise. `FindCommands` is new in `CaravanUI`; the rest is
`ScrollbackTextView` and one call in `MessageLogController`.

### Decision — `NSTextFinder`, and therefore an undeclared conformance

The scrollback is an `NSTextView`, so ⌘F is wiring rather than searching: incremental
highlighting of every match, "3 of 47", ⌘G, ⇧⌘G and ⌘E all come with the platform's find
bar, and they behave as they do in every other window on the machine. A hand-rolled bar
would be worse in a dozen small ways nobody lists in advance.

The interesting part is *which* finder. `usesFindBar = true` is one line and gives
`NSTextView` a private one — which cannot be told anything. This view is appended to and
trimmed from underneath an open search constantly, and the documented way to keep a finder
honest across that is `noteClientStringWillChange()`. So `ScrollbackTextView` owns its
`NSTextFinder` and forwards `performTextFinderAction(_:)` to it.

That costs a **retroactive conformance**: `NSTextView` has implemented `NSTextFinderClient`
since 10.7 — it is exactly what `usesFindBar` relies on — but does not declare it in a
header, so Swift will not let you assign one as a client without
`extension ScrollbackTextView: @MainActor NSTextFinderClient {}`. Worth the trade: the
alternative is a find bar that highlights whatever slid into the range it remembered.

### Decision — ⌘F is the window, and says so by naming the other place

Prompt 12's note asked for this to be decided rather than left as two searches that disagree
about what "everything" means. It is: **⌘F never widens to the log**, because a find that
sometimes returns lines you cannot see is a find you cannot trust. Next to it in the same
menu is `Find in Log…` (⌥⌘F), which opens the existing log viewer on this buffer, seeded
with the search string.

The string comes from **the find pasteboard**, which is where macOS keeps it and where ⌘E
writes it. `NSTextFinder` does not hand out its query, and reaching into the bar's views for
it would be reading somebody else's UI.

### Decision — ⌘C is plain; ⇧⌘C keeps the colours

A departure from the platform default, where `NSTextView` writes RTF and plain together and
lets the destination choose. The reason is concrete: the palette is built for a dark window,
so rich text carried out of one arrives as pale grey on white in most documents and half of
it is unreadable. Plain is what somebody pasting into a bug report, a terminal or a message
wants nearly every time, and it is the one that cannot arrive invisible.

The styled form is built here rather than by `writeSelection(to:types:)`, which asks the
view for its writable types — and this view is deliberately `isRichText = false`, which is
what stops styled text being *pasted in*, so it offers no RTF to write. The styling is in the
storage either way. The plain form is the selected range's own characters rather than a
re-render through `LineRenderer.plainLine`: a selection may be half a line, and what the
buffer is showing is what somebody dragged over.

### What the tests assert, and what they do not

`NSTextFinder` owns the matching, the highlighting and the counter; testing those would be
testing AppKit. What is asserted here is this client's share: that a finder exists on every
scrollback, that the buffer stays coherent while it is appended to and trimmed under an open
search, that an unrecognised sender is ignored rather than guessed at, and — with a
pasteboard of the test's own rather than the one belonging to whoever is at the machine —
exactly what each copy command puts on it.

### The live run, and the two defects it found

Both were the same shape: the feature was **present, enabled and inert**, which is the
failure mode no unit test catches because every part of it works in isolation.

**`NSTextView` validates finder actions against `usesFindBar`.** That flag is off here —
this view owns its finder instead — so `validateUserInterfaceItem` answered "no" and the
responder chain dropped ⌘F before it could reach `performTextFinderAction(_:)`. The menu
item was there and did nothing. Overridden to answer for itself.

**And the responder chain was the wrong mechanism anyway.** With the validation fixed, ⌘F
still did nothing, because a chain send goes to whatever has focus — and what has focus when
somebody reaches for ⌘F is the input box they were typing in, or the window itself after
they clicked a row in the tree. Clicking the transcript *does* make it first responder, so
this looks correct in a test and fails for every real user. `FindCommands` now asks the key
window for its scrollback and calls it directly, which also settles a question the chain
would have answered wrongly: ⌘F searches the transcript, never the input box.

### What the run confirmed, in `#linux` with 2451 members and traffic arriving

- ⌘F opens the bar; typing `initramfs` incrementally highlighted the matches and showed
  **3**; ⌘G walked forward and ⇧⌘G back, moving the current match each time.
- The bar stayed open and correct through half a minute of a busy channel appending under
  it, which is the case `noteClientStringWillChange()` exists for.
- **⌘C put 5,509 bytes of plain text on the pasteboard and no `«class RTF »` at all.**
  ⇧⌘C put 7,965 bytes of RTF there alongside it. Pasted into TextEdit, the first arrives as
  unstyled Helvetica and the second keeps the nick colours, the links and the monospace.
- `Find in Log…` opened the viewer already scoped to `libera` / `#linux` with **`initramfs`
  in its filter field**, carried across on the find pasteboard, showing the three matching
  lines. That is prompt 12's "way across", working.

**Not verified live: ⌘F in a *detached* window.** Detaching is only offered on the tree
row's context menu, and `System Events` cannot right-click — the limitation prompt 9
recorded — and `AXShowMenu` on the row returns `missing value`. The code path is not
separate: `scrollbackInKeyWindow()` reads `NSApp.keyWindow`, and a detached buffer is simply
that window instead. Worth a human's thirty seconds the next time one is open.

---

## Decision — a fresh install starts with the ten largest networks

**Date:** 2026-08-10  **Affects:** `DefaultServers`, `ServerList`, `DashboardCanvas`

GUI-DESIGN-NOTES §13 has always said the Dashboard holds "pre-populated entries to connect
to, plus Add Server". Prompt 11 shipped the list and the editor; the entries never arrived,
so a first run showed "No servers yet" and a user who did not already know a hostname had
nowhere to go. `DefaultServers` is that missing half: the ten largest IRC networks by
measured concurrent users, from netsplit.de's mid-2026 figures.

### Every endpoint was connected to before it was written down, and that mattered

Of the ten hostnames the public rankings give, **five did not work as published**:
`irc.ircnet.net` and `open.ircnet.net` do not resolve at all; `irc.efnet.org` presents a
self-signed certificate; and Undernet and QuakeNet *refuse* 6697 — connection refused, not a
timeout, and plain 6667 answers immediately on the same hosts, which is what proves it is
policy rather than a firewall. Shipping the published list unchecked would have given a new
user a list where half the entries fail in a different way each.

What ships is what answered a TLS handshake, with IRCnet pointed at `ircnet.hostsailor.com`
— a real IRCnet server with a certificate that verifies — and EFnet left on its self-signed
certificate, which trust-on-first-use already handles by asking once.

### Decision — two of them ship in cleartext, and the app says so

Undernet and QuakeNet have no TLS to offer. The choice was between omitting two of the
largest networks on the internet and shipping two entries that are not encrypted. **The
user's call, and they took the literal top ten**, so both ship on 6667 with `tls = false`.

The mitigation is that it is *visible*: `ServerRow` marks any entry without TLS with a
`lock.slash` and the tooltip "Not encrypted — this network offers no TLS". Not special-cased
to those two — a hand-written cleartext entry deserves the same warning. A default the user
cannot see the shape of is the part actually worth avoiding.

freenode ships too, on the same principle: it is measurably tenth by users, its TLS works,
and a pre-populated list is a convenience rather than an endorsement. Also the user's call,
asked because inclusion in a shipped list is a recommendation whether or not it is meant as
one.

### Decision — written into the file, and only when there is no file

Seeding writes real entries to `servers.conf` rather than holding defaults in the binary,
because the file is the truth: it is documented, hand-editable and a public path, and
defaults that existed only in code would be defaults nobody could diff, comment out or
delete. The seeded file is ordinary and readable — ten three-line stanzas under the standard
header.

**"First run" means the file does not exist, not that it holds nothing.** Somebody who
deletes every entry has said something, and a client that answers by putting ten networks
back is arguing with them. That distinction costs one `fileExists` and is the whole
difference between a starting point and a nag. Seeding is also opt-in at the call site —
`ServerList(seedingDefaults:)`, true only for `shared` — so every test still gets the empty
list it asked for rather than ten surprise networks.

Nothing connects on startup and nothing is a favourite. A client that dialled ten networks
the first time it opened would announce a stranger's arrival on ten networks.

### Verified live

A genuinely empty profile showed all ten on the Dashboard with the lock-slash on exactly
Undernet and QuakeNet. Two shipped entries were then dialled unmodified through the real
client: **OFTC over TLS** (registered, 12,906 global users, MOTD art intact) and **Undernet
over cleartext 6667** (registered, `NETWORK=UnderNet`, 4,805 users). The other eight are
verified only as far as a TLS handshake and a first line from the server, which is what the
probe script checked.

**This list will rot.** It is a starting point with a date on it, not a maintained registry;
the entries are editable and deletable, and nothing in the app depends on them.

---

## Decision — `make install` puts a Release build in /Applications

**Date:** 2026-08-10  **Affects:** `Makefile`, `Scripts/install-app.sh`, README

Asked for directly: the latest build should be in `/Applications`, so it can be used rather
than launched out of `DerivedData` by a script. Three things had to be decided.

**Release, not Debug.** `make app` builds Debug and stays that way — an acceptance run wants
assertions live. What somebody uses all day should be optimised, so `install` is a different
configuration on purpose rather than by accident. Release was checked to build clean under
the same warnings-as-errors settings before this was written.

**The product path is asked for, never written down.** `DerivedData` is keyed on the
project's path, so every worktree has its own folder and a hard-coded path installs whichever
checkout built there last. This log records that mistake four times, twice as a "defect" in
code that had already been fixed. `install-app.sh` reads `BUILT_PRODUCTS_DIR` and
`FULL_PRODUCT_NAME` from `xcodebuild -showBuildSettings`, exactly as `run-app.sh` does, and
prints the source path and the commit — with `(dirty)` when the tree has uncommitted changes,
because "why is my fix not in there" is usually answered by that word.

**The swap cannot leave a half-written bundle, and cannot delete anything it was handed.**
`ditto` into a staging path beside the target, move the previous bundle aside, move the new
one in, and let a trap clean both up. `shellcheck` caught the first draft doing
`rm -rf "$destination/$name"` on values that could in principle be empty — the `rm -rf /`
case — so both removals now name only paths the script itself created, under its own prefix,
guarded by `${var:?}`.

Verified by installing and launching the installed copy under a throwaway `XDG_CONFIG_HOME`:
it opens, seeds the ten default networks and marks the two cleartext ones. Running it against
the developer's own profile is deliberately *not* part of the check — that would connect as
them, to their networks, without being asked.

---

## Decision — the running app notices when it has been replaced

**Date:** 2026-08-10  **Affects:** `BuildWatcher`, `UpgradeBanner`, `RootView`, `CaravanApp`

`make install` replaces `/Applications/Caravan.app` underneath a running copy, which keeps
executing the code it started with. That is a confusing way to discover a fix did not land —
the app looks current and is not — so it now says so: a one-line bar above the chat area,
with **Later** and **Restart**.

### Decision — a bar, not an alert

News rather than a question. The running copy is still perfectly usable, and interrupting
somebody mid-sentence to announce a build they did not ask for would be worse than the
confusion it prevents. It takes one line, it is dismissible, and dismissing is remembered
**per build identity** rather than as a flag — otherwise waving one away would silence every
future build for the life of the process.

### Decision — polled, not watched with a `DispatchSource`

The bundle is *replaced* rather than written to, so a descriptor held on the old executable
is a descriptor on a file that has been moved aside and deleted; re-arming means re-opening
the path anyway. A loop that sleeps to a deadline is the shape `IRCSession.idleMonitor()` and
`ChannelDirectory` already use, costs one `stat` a minute, and cannot get stuck watching a
path nothing will touch again. `check()` also runs when the window becomes active, which is
when somebody who has just run `make install` in a terminal is most likely to be looking.

### Three details that came out of watching it actually run

**The identity is size + mtime + inode, and the inode is the one that earned its place.** The
live run replaced the bundle with a build xcodebuild had not relinked: same size, same
modification date to the second, different inode. Size and mtime alone would have seen
nothing. `stat` on the running process's own binary confirmed the split — the process was
executing inode 91862675 while the path held 91862992.

**An absent file is "ask again later", never "it changed".** `install-app.sh` moves the old
bundle aside and then moves the new one in, so a poll landing between those two sees no file
at all — and a watcher treating that as a new build would announce one a fraction of a second
before it was true. There is a test for exactly that sequence.

**The replacement is launched after this process is gone, not before.** Two copies running
share one `$XDG_CONFIG_HOME`, and two processes writing one `caravan.conf` is a way to lose
settings that is much harder to explain than the second of delay a `sleep 1; open` costs.

### Verified live, and one thing that was not

Installed over a running copy: the poll logged the differing inode and the bar appeared with
both buttons. The relaunch command the button runs was verified on its own — process count 0
then 1 — but **the Restart button was never clicked**, because `osascript` lost assistive
access at the moment the bundle was swapped and never got it back in this session. Whether
replacing the bundle caused that is not proven, only observed; it is worth knowing that a
`make install` can cost the machine's automation grants until they are re-approved.

**Diagnosing this needed instrumentation, and the first two attempts at it were wasted.**
`Log.ui.info` produced nothing in `log show` even with `--info` and `--debug`, for reasons not
chased down. Writing to `stderr` worked immediately, because the acceptance launcher already
captures it — worth remembering before spending another round on the unified log.

### Not fixed here, and now recorded

Quitting Caravan — by ⌘Q or by this button — drops connections without sending `QUIT`, so
servers report a dropped link rather than a departure. That is pre-existing behaviour rather
than something Restart introduced, and it is now in `PLAN.md`'s **Still open**.

---

## Three visual corrections, all from someone looking at it

**Date:** 2026-08-10  **Affects:** `RootView`, `SidebarTree`

**The connection dot spilled out of its toolbar item.** It was a `Label` with
`systemImage: "circle.fill"`, which lays the symbol out on the text baseline at full body
size — and macOS gives a toolbar item a rounded background of its own, so the symbol sat
hard against the left corner and read as escaping it. It is now a drawn 7pt `Circle`, the
same dot the tree and the server list use, inset from the corner deliberately. Worth
remembering: an SF Symbol sized by the font is the wrong tool for a fixed-size indicator
inside somebody else's rounded rectangle.

**"Settings & Debug" was tight against the sidebar's rounded corner.** 10pt of horizontal
padding put it visibly closer to the edge than the rows above it, which the sidebar's own
corner radius cuts into at the bottom. Leading is now 13pt and trailing stays 10pt —
deliberately asymmetric, because the thing being cleared is only on one side.

**The new-build banner covered the top of the content instead of moving it.** It was a
`safeAreaInset(edge: .top)`, which reserves space only for content that honours the safe
area — the Dashboard's first rows were simply hidden behind it. It is a `VStack` now, so the
banner takes real layout space and the content starts below it. It still takes none when
there is nothing to say, because `UpgradeBanner` resolves to nothing when the notice is not
showing. The previous entry's description of *where* the banner sits was right; the
mechanism it named was not.

None of the three is visible in a test, and all three were obvious in a screenshot.

---

## Decision — the tree is set in the system font, and §12 was describing something that never happened

**Date:** 2026-08-10  **Affects:** `SidebarTree`, GUI-DESIGN-NOTES §12

Asked to change the font on the pinned "Settings & Debug" row. Looking at why it needed
changing turned up something better than a font preference.

**§12 has said since stage 1 that "the tree is set in a monospaced font", and it never
rendered that way.** `SidebarTree` applies `.font(chatFont)` to its `List`, and
`.listStyle(.sidebar)` overrides a font applied to the list for the rows *inside* it — so
every row in the tree has been system-font since the first build. The note went four stages
without anybody noticing it described a different app.

What made it visible was the one row that is **not** inside the list: pinned "Settings &
Debug" sits in a `safeAreaInset`, where the modifier does apply. So exactly one row in the
sidebar honoured the design note, and it was the row that looked wrong.

**The choice was put to the user, because it is a taste question with two defensible
answers**: force monospace onto rows that have looked native all along, or change the note
to say what the app does. The app won. The column-of-sigils argument in the original note
was real, but it was buying tidiness in a sidebar rather than legibility in a transcript —
and §4's scrollback, where that argument does earn its keep, is untouched.

So: the `.font(chatFont)` on the list is gone (it did nothing), the one on the pinned row is
gone (it did the wrong thing), the now-unused `@Environment(\.chatFont)` with it, and §12
records what happened rather than being quietly overwritten — the original wording is still
in the note, above the correction.

**Worth keeping in mind generally:** a design note that has never been checked against a
screenshot is a note that might be describing a different program. This one survived four
stages, a hundred-odd prompts and a mechanical docs check, because nothing it claimed was
ever mechanically true or false — only visible.

---

## Decision — the toolbar is removed, and §8 says why

**Date:** 2026-08-10  **Affects:** `RootView`, `NavigationCommands`, `ChannelBufferView`,
GUI-DESIGN-NOTES §8

Asked what the pill at the top of the window was for. Answering it honestly made the case
for deleting it: three items, each overtaken by something already on screen.

- **Connection state** was not interactive at all. It duplicated the window subtitle
  directly beneath it *and* the state dot on every network row — and unlike either of those
  it could only ever describe the *active* connection, so with two networks open it was the
  least informative of the three.
- **`+` / Servers…** duplicated the Dashboard row pinned at the top of the tree. It only
  survived this long because prompt 4's live run found that hiding Connect made
  multi-network unreachable — an argument that expired the day the Dashboard got a row.
- **The nick-list toggle** wore `sidebar.right`, inches from the real sidebar toggle, so it
  read as a second one. It never appeared in a detached window, so ⌃⌘L was already the route
  that always worked.

**Losing nothing was easy, and the original note is why.** §8's strongest argument was to
use `NSToolbar` so macOS gives customization away — which forced the rule that every toolbar
item must also be a menu item, since the user can drag any button off. Four stages later
that rule is what made this a deletion rather than a redesign: all three were already menu
items with shortcuts.

**Kept: the detached window's Reattach button.** That window has no tree to close it from,
so it is the affordance rather than a duplicate of one.

The window now shows its title, its subtitle and the system's own sidebar control, which is
what a document window looks like on this OS.

**Worth noticing about the shape of this.** Nothing here was a bug and no test could have
failed. Three separate prompts each added a correct item to a toolbar, and the tree grew
past all three one row at a time — so the toolbar decayed by accretion elsewhere. That is
the kind of rot only somebody looking at the window finds.

---

## Two defects found by somebody using the client

**Date:** 2026-08-10  **Affects:** `ConnectionViewModel.destinations(for:)`, `SidebarTree`

### A refused message looked like nothing happening

Reported as "do I need some sort of permission to send?", which is precisely the question
the failure provokes. Speaking in a `+m` or `+r` channel is refused by the server with 404,
and **every numeric went to the status window** — so the channel showed no echo, no error,
and the message simply vanished. Two windows away, in a buffer the user had no reason to be
looking at, sat `##caravan-perm Cannot send to nick/channel`.

Reproduced against Libera rather than argued about: a scripted client held a channel of its
own, joined first so it was opped, and set `+m`; the app then joined and sent one line
through the ordinary `submit` path. The channel showed the join and nothing else. That
screenshot is the bug.

**A numeric that names an open channel now lands in that channel.** The rule skips the first
parameter (always our own nick) and the last (the human-readable text): everything between
them is the numeric's actual arguments, which is where a channel name *is* a channel name.
Routing on the trailing text would put a line in a window because of a sentence — "You are
not on #swift" would jump into `#swift` — so there is a test for that case specifically.

### A channel could not be closed from its own row

Query rows have carried "Close Conversation" in their context menu since prompt 5; channel
rows never had an equivalent. Closing a channel was ⌘W or the Network menu — everywhere
except the row you were right-clicking. Now "Close Channel", named for what it does rather
than for `PART`, because §16's rule is that membership never outlives its buffer: closing
*is* parting, and offering both words invites the question of which one you meant.

**Not verified by automation:** the context menu itself. `System Events` cannot right-click
and `AXShowMenu` returns `missing value` on these rows — the limitation prompt 9 recorded.
The item is a one-line mirror of the query row's, which does work.

### Worth keeping

Both of these are *older* than any of today's work — the numeric routing has behaved this
way since prompt 5, and the missing menu item since the tree was built. Neither is visible
in a test suite that asserts what a function returns, and neither showed up in a hundred
prompts of acceptance runs, because every acceptance run was driven by somebody who knew
where the status window was. The first hour of somebody actually *using* it found both.

---

## Defect — the input box wrapped after about one word

**Date:** 2026-08-10  **Affects:** `InputField`

Reported as "the input window at the bottom line wraps automatically when typing in it".
Measured: the field was **1676 points wide** and wrapped after `the`. Everything past the
first word wrapped below a one-line clip, out of sight — so text went in and appeared to
vanish, which is almost certainly what the earlier "I can't type anything in" report was.

### The numbers, because guessing cost two attempts

Instrumented and read off a running client:

```
content=1676.0  frame=1676.0  container=49.0  tracks=true
```

The clip view and the text view were the right width; the **text container** was 49. Two
independent faults produced that, and the first fix only addressed one:

1. `autoresizingMask` resizes a document view when its clip view *changes* size. A view
   installed into a clip view that is already correct is never resized, so it kept the
   nothing-sized frame it was born with. Fixed by stating the width in `updateNSView`, which
   is the one place that knows it.
2. **`sizeThatFits` moved the container to measure and left it moved.** SwiftUI probes with
   several proposals, some very narrow, and the last one stayed. Measuring is now bracketed
   by a `defer` that puts it back.

### What the test caught that the app did not

The first version of the restore assigned `containerSize` directly. A test measuring the
same text at 900 points and at 200 got *the same height*, which is how it came out that with
`widthTracksTextView` the container is **derived** from the text view's width on every
layout — so assigning it is quietly discarded. Measurement now moves the frame and restores
it, which is the thing the view actually respects.

That is the argument for extracting `InputField.size(of:fittingWidth:maximumLines:)` out of
the representable: the defect is a *side effect* of measuring, so the assertion has to be
about the text view afterwards, and a `Context` cannot be built in a test.

### Worth keeping

`MessageLogView.makeTextView` sets `minSize`/`maxSize` and an explicit frame on the
scrollback and has been fine for four stages; the input, built two prompts later, set
neither. The same two lines, missing in one of two nearly identical views, and no test could
see it because both views report perfectly sensible sizes to everything except the
typesetter.
