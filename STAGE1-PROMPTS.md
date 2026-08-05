# Stage 1 — The Ten Prompts

**Status:** 2/10 complete. Next: prompt 3.

Each block is a self-contained prompt. They assume the previous ones are done and
merged. Every prompt has a **Do not** section — that's the scope fence that keeps
stage 2/3 work from leaking backward.

Standing rules (Swift 6 strict concurrency, macOS 15, swift-testing, zero warnings,
zero external dependencies) live in `CLAUDE.md` and load automatically — they don't
need restating per prompt. `CLAUDE.md` also carries the end-of-prompt obligations.

Each prompt is one branch (`prompt-NN-slug`), one PR, squash-merged to `main` once CI
is green. Bump the **Status** line above in the same PR — `make check` fails if it is
missing or malformed.

### Carry-forward notes

When work on one prompt turns up something a later prompt needs to know, the note is
appended to **that prompt, in this file**, under a `### Carry-forward` heading:

```
### Carry-forward
- From prompt 4: NWConnection reports .ready before the TLS handshake completes,
  so don't start the registration timer here — wait for the first byte.
```

Notes live in the destination rather than a separate file because this file is
already re-read at the start of every prompt. There is no second place to remember to
check. A note is **deleted when the prompt that received it runs**, and the fact that
it was applied is recorded in `BUILD-LOG.md`. `make check` fails if a note is still
attached to a prompt the status line says is complete.

For notes aimed at **stage 2 or later**, where there is no prompt to attach to, append
the same block under the relevant numbered item in `PLAN.md`. Same rule: consumed and
deleted when that item is built.

---

## Prompt 1 — Scaffold

```
Set up the project skeleton. The repo already exists with planning docs and the docs
CI on `main`; do not re-init it. Branch `prompt-01-scaffold`, open a PR.

Create:
- A SwiftPM package `IRCClient` with library targets: Diagnostics, IRCProtocol,
  IRCTransport, IRCSession, plus matching test targets. Targets get a single stub
  type each; do not implement them. Do not create modules we don't use yet.
- An Xcode project `irc-client.xcodeproj` with a macOS app target depending on the
  local package: SwiftUI lifecycle, macOS 15 minimum, hardened runtime, network
  client entitlement. Not sandboxed — DCC and identd need incoming connections later.
  Naming, so this is not re-litigated: target and product `IRCClient` (no library
  product shares that name, so there is no clash with the package), display name
  "IRC Client", bundle id `com.lacuna-research.irc-client`. All of it is a working
  name — see the rename gate in PLAN.md stage 4.
- Swift 6 language mode, StrictConcurrency=complete, and warnings-as-errors ON.
  Zero-warnings is a rule, so make the compiler enforce it rather than trusting us.
- Formatting via the toolchain's built-in `swift format` (6.3.0 ships with it) plus a
  `.swift-format` config. Do NOT add SwiftFormat or SwiftLint — strict concurrency
  and warnings-as-errors already cover most of their value, and both would be
  external dependencies we've committed to living without.
- Makefile targets `build`, `test`, `fmt`, `lint` alongside the existing `hooks` and
  `check`. Shell scripts start with `set -euo pipefail` and pass shellcheck.
- README build/test/run instructions filled in.

Swift CI at `.github/workflows/ci.yml`, on pull_request and pushes to main. The repo
is public, so macOS runner minutes are free and unmetered — run the full matrix
rather than rationing it:
- Job `purity` on ubuntu-latest: build and test IRCProtocol alone. This is a cost
  optimization AND a rule enforcement — Linux has no AppKit, no Network.framework and
  no Darwin os.Logger, so the job fails the moment IRCProtocol stops being pure.
- Job `macos` on macos-latest: `swift build`, `swift test`, and
  `swift format lint --strict --recursive Sources Tests`.
- Cache `.build` keyed on Package.resolved.

Acceptance: `make build test lint check` all clean, the app launches to a single
empty window titled "IRC Client" containing a NavigationSplitView placeholder (empty
sidebar, empty detail), and every CI job passes on the PR.

Do not: write any IRC logic, networking, diagnostics, or UI beyond the empty split
view. Diagnostics is prompt 2 — leave it a stub.
```

---

## Prompt 2 — Diagnostics

```
Implement the Diagnostics module. Keep it small — this is a thin layer, not a
framework.

- `Log`: namespaced `os.Logger` instances, one per subsystem/category
  (transport, protocol, session, ui). Subsystem string from the bundle id.
- `Redactor`: a pure function taking an inbound or outbound IRC line and returning it
  with credentials replaced by <redacted>. Must cover PASS, AUTHENTICATE, OPER, and
  PRIVMSG/NOTICE to NickServ matching identify/ghost/regain/release/setpass —
  case-insensitively, tolerating the `/msg NickServ IDENTIFY` and `NS IDENTIFY`
  spellings. Pure and table-tested; this is security-relevant code, not a convenience.
- `TraceBuffer`: a fixed-capacity in-memory ring of timestamped wire events
  (.inbound/.outbound, raw line, monotonic timestamp). Configurable capacity,
  default a few thousand entries. Thread-safe. Redaction applied on insert, not on
  read, so a credential is never resident in the buffer.
- `Signposts`: an OSSignposter for perf intervals; prompt 7 uses it for the
  scrollback benchmark.

Acceptance: tests green, and the Redactor table includes negative cases — an ordinary
message containing the word "identify", a nick called "pass", and a channel message
merely mentioning a password must all pass through untouched. Over-redaction destroys
the debuggability the trace buffer exists for.

Do not: build log routing, pluggable backends, custom level hierarchies, log
rotation, remote shipping, or any log viewer UI. No IRC parsing — this module must
not depend on IRCProtocol; it operates on raw line strings.
```

---

## Prompt 3 — Message parser

```
Implement IRCProtocol: parsing and serializing IRC protocol messages. Pure value
types, zero I/O, no Foundation networking, no Darwin-only APIs — the CI purity job
builds this target on Linux and will fail if that slips.

Types:
- `IRCMessage`: tags, source, command, parameters
- `IRCTags`: ordered key -> String? (valueless tags are distinct from empty-valued),
  with the IRCv3 escape rules on parse and serialize: \: -> ;  \s -> space
  \\ -> \  \r -> CR  \n -> LF; a lone trailing backslash is dropped; unknown
  escapes drop the backslash.
- `IRCSource`: .server(String) or .user(nick:user:host:) — parse nick!user@host with
  either or both of user/host absent.
- `IRCCommand`: .verb(String) / .numeric(UInt16), preserving 3-digit zero padding on
  serialize.
- Parameters: last param may be trailing (`:foo bar`). A param that is empty, starts
  with `:`, or contains a space MUST be serialized as trailing.

Also here (pure, and the parser-tests corpus covers them):
- `IRCCaseMapping`: .ascii, .rfc1459, .rfc1459Strict — with `foldedCase(_:)` and a
  case-insensitive comparable `IRCNick`/`IRCChannelName` wrapper suitable for
  dictionary keys.
- Wildcard mask matching (`*`, `?`) for nick!user@host, casemapping-aware.

Limits: enforce 8191 bytes for the tag section and 512 bytes (including CRLF) for the
rest; expose these as constants and provide `truncated(to:)` rather than silently
corrupting.

Tests: vendor the ircdocs/parser-tests YAML corpus (msg-split, msg-join,
userhost-split, mask-match) into Tests/Fixtures and drive table tests from it. Record
the upstream commit SHA in Tests/Fixtures/VENDOR.md and in the BUILD-LOG entry —
"we pass the corpus" is unfalsifiable later without knowing which corpus. Add
hand-written tests for the nasty cases: empty trailing, trailing that is just ":",
tags with no value vs empty value, source with no user, 8-bit/invalid UTF-8 bytes in
the trailing param.

Do not: implement ISUPPORT, CTCP, formatting codes, or anything touching a socket.
```

### Carry-forward

- From prompt 1: the CI `purity` job currently runs only `swift build --target
  IRCProtocol` on Linux. It does **not** run this module's tests there, because
  `swift test --filter` still builds every test target, and Diagnostics will import
  `os.Logger` from prompt 2 onward and cannot compile on Linux. Once there are real
  parser tests worth running cross-platform, find a way to build and run
  `IRCProtocolTests` alone — a separate Linux-only package manifest, or a
  `--filter` combined with excluding the Darwin targets. Portability of the parser
  is worth actually testing, not just asserting.

---

## Prompt 4 — Transport

```
Implement IRCTransport: a connection that turns a socket into a stream of IRCMessage
and accepts messages to send. IRC semantics do not belong here.

- `LineFramer`: a pure struct taking Data chunks and yielding complete lines. Splits
  on \r\n but tolerates a bare \n. Handles a line split across arbitrarily many
  chunks. Lines longer than the protocol limit are dropped with a diagnostic rather
  than buffered forever. Testable with zero networking — test it first and hard, it's
  where framing bugs hide.
- Decoding: try UTF-8; on failure fall back to Windows-1252 rather than dropping the
  line. Real IRC networks still carry 8-bit garbage and losing those lines is worse
  than mojibake.
- `IRCConnection`: an actor wrapping NWConnection.
  - `connect(host:port:tls:)` where tls is .disabled or .enabled(allowSelfSigned:Bool)
  - `inbound: AsyncStream<IRCMessage>`
  - `send(_ message: IRCMessage)` — serialize, enqueue, write in order, never
    interleave partial writes.
  - `state: AsyncStream<TransportState>` mapping NWConnection states to
    .idle/.connecting/.ready/.failed(Error)/.cancelled
  - `disconnect()` that is idempotent and distinguishable from a network failure.
- Use NWProtocolTLS. Self-signed acceptance goes through an explicit
  `sec_protocol_options_set_verify_block` — surface the certificate to the caller,
  do not blanket-trust.

Tracing: every line in and out goes to the Diagnostics TraceBuffer at the point of
serialization/framing — one call site each direction, so traffic cannot bypass the
trace. Use Log.transport for connection lifecycle at .info and errors at .error. Do
not log message payloads through os.Logger; payloads live in the TraceBuffer only.

Tests: LineFramer units including chunk boundaries mid-CRLF; an integration test that
stands up a local NWListener, connects, and round-trips messages both directions.
Assert that a PASS line reaches the wire intact but appears redacted in the
TraceBuffer.

Do not: implement reconnect/backoff, PING/PONG, registration, or any numerics — those
are prompt 5. No CAP, no SASL, no proxies, no client certificates.
```

---

## Prompt 5 — Registration and connection state machine

```
Implement IRCSession's connection lifecycle on top of IRCTransport.

Registration: optional PASS, then NICK, then USER <ident> 0 * :<realname>.
- On 433 during registration: try the alt nick, then append "_" progressively up to
  NICKLEN, then fail with a clear error.
- On 001 the session is registered; capture 002/003/004 server info.
- Parse every 005 ISUPPORT line into a `ServerCapabilities` struct with typed
  accessors: PREFIX (mode chars -> prefix chars, ordered by rank), CHANMODES (four
  groups), CHANTYPES, CASEMAPPING, NETWORK, NICKLEN, CHANNELLEN, TOPICLEN, MODES,
  TARGMAX, STATUSMSG, MONITOR. Support token negation (-TOKEN) and unknown tokens
  (keep the raw string, don't discard). The parsed CASEMAPPING must drive the
  IRCCaseMapping used everywhere downstream.
- Reply to PING with PONG carrying the same token. Handle ERROR as a server-initiated
  close with the given reason.
- Idle detection: if nothing arrives for N seconds send our own PING; if no response
  within M seconds, treat the connection as dead. Both configurable.
- Reconnect: exponential backoff with jitter and a ceiling, attempt counter, hard stop
  when the user disconnected deliberately. Must not fire while a connect is in flight.

`SessionState`: .disconnected(reason), .connecting, .registering,
.connected(ServerInfo), .reconnecting(attempt: Int, nextAttemptIn: Duration).

Tests: build a scriptable fake IRC server (an NWListener playing a canned exchange and
asserting what it receives). Cover happy-path registration, nick collision with
fallback, PING/PONG, server ERROR, idle timeout, backoff schedule, and that a
deliberate disconnect does not reconnect.

Do not: track channels or users (prompt 8). No CAP negotiation, no SASL — stage 2.
No UI.
```

---

## Prompt 6 — Typed event model

```
Introduce IRCEvent as the single seam between IRCSession and everything above it, and
route all inbound traffic through it.

`enum IRCEvent: Sendable`, covering at least:
  .stateChanged(SessionState)
  .registered(ServerInfo)
  .message(target: Target, sender: IRCSource, text: String, kind: .privmsg/.notice,
           isAction: Bool)
  .joined / .parted / .quit / .nickChanged / .kicked / .topicChanged / .modeChanged
  .namesReply / .endOfNames
  .numeric(code: UInt16, params: [String])
  .clientError(String)   // our own diagnostics, e.g. "unknown command"

Hard rule: every inbound IRCMessage also emits `.raw(IRCMessage)` regardless of
whether it was recognized. Nothing the server sends may become invisible — that is
what makes the status window trustworthy and debugging possible.

Delivery: the session needs multiple independent consumers (UI, logger, later
scripting), so a single AsyncStream is not enough. Implement a small multicast —
`events()` hands each caller its own AsyncStream, with a bounded buffer and a
documented drop policy for a slow consumer. State in a comment what happens when a
consumer stalls.

Refactor prompt 5's internals to emit these events rather than exposing raw messages.
Keep a `Target` type distinguishing channel from nick, casemapping-aware.

Tests: table-driven — given this raw line, assert exactly these events in this order.
Include a test that an unrecognized command still yields .raw and nothing else.

Do not: add channel/user state (prompt 8), and do not build UI.
```

---

## Prompt 7 — Minimal UI and the scrollback view

```
Build the first real UI. The scrollback view is the load-bearing component — build it
properly now, because retrofitting it later means rewriting the app.

`MessageLogView`: an NSViewRepresentable wrapping NSTextView inside an NSScrollView.
- Non-editable, selectable, link detection on, no rich-text input.
- Append-only API: `append(_ lines: [AttributedString])` doing ONE batched
  textStorage mutation per flush (beginEditing/endEditing), not one per line.
  Coalesce appends on a short timer so a MOTD burst is a handful of mutations.
- Auto-scroll to bottom only when already pinned to the bottom. If the user has
  scrolled up, hold position and show a "jump to latest" affordance.
- Trim from the top past a configurable line cap so memory stays bounded.
- Benchmark before calling it done: 50,000 lines appended, then scroll top to bottom.
  Instrument with the Diagnostics signposter and profile in Instruments. Report real
  numbers in the BUILD-LOG entry — append throughput, scroll frame time, peak memory.
  Start with TextKit 2 (the default); if the numbers are bad, fall back to
  NSTextView(usingTextLayoutManager: false) and record why.

App structure:
- `@MainActor @Observable` view models consuming IRCSession's event stream.
- NavigationSplitView: sidebar lists the connection and its status window; detail is
  the scrollback view with a single-line input field beneath it.
- A Connect sheet: hostname, port, TLS toggle, nick, alt nick, ident, real name.
  Persist just the last-used values with @AppStorage as a stopgap.
- Connection status and errors visible in the UI, not just the console.

Acceptance: connect to irc.libera.chat:6697 over TLS, watch the full MOTD render in
the status window, and confirm scroll-lock works while it is still streaming. A local
soju is the better target for repeated iteration — stage 1's optional PASS is enough
to reach it, using `<user>/<network>` as the username.

Do not: multiple servers, channel windows, nick lists, formatting codes, logging, or
a preferences window.
```

---

## Prompt 8 — Channel and user state

```
Add channel membership tracking to IRCSession, and the channel window to the UI.

Model (inside the session actor, exposed as immutable snapshots):
- `Channel`: name, topic + who set it + when, members, own membership status.
- `Member`: nick, user, host if known, and the set of prefix modes held.
- All nick and channel keys use the casemapping from ISUPPORT — a server saying
  CASEMAPPING=rfc1459 must treat "Foo[]" and "foo{}" as the same nick.

Transitions: JOIN (self vs. other — self-join creates the window), PART, KICK, QUIT
(remove the user from every channel shared with us, reported per-channel), NICK
(rename across all channels), 353/366 NAMES (parse ALL leading prefix characters per
nick, not just the first — multi-prefix is stage 2 but the parser should already be
correct), 332/333 topic, 331 no topic, 324 channel modes, and the join-failure
numerics (471/473/474/475/476/477) surfaced as usable errors.

Nick list ordering: by prefix rank as declared by ISUPPORT PREFIX (not a hardcoded
@%+ list), then casemapped alphabetical.

UI:
- Sidebar gains channels nested under their network.
- Channel window: topic bar across the top, scrollback, nick list pane on the right
  with a member count, input field below.
- Joins/parts/quits/kicks/nick changes/mode changes render as distinct event lines.

Tests: state-transition tests driven by scripted server output, including the awkward
ones — QUIT removing a user from three channels at once, a nick change colliding with
casemapping, NAMES arriving in several batches.

Do not: context menus, mode dialogs, ban lists, or user-facing mode editing.
```

---

## Prompt 9 — Command line

```
Implement the input command layer.

Parsing: a leading "/" introduces a command; "//" sends a literal leading slash.
Everything else is a message to the current window's target.

Commands for this stage:
  /join /part /msg /query /me /notice /nick /topic /quit
  /server /connect /disconnect
  /raw (alias /quote)
Unknown /commands are uppercased and sent to the server verbatim — that is how mIRC
behaves, and it makes the client immediately useful for anything not yet wired up.

Semantics that matter:
- /msg and /me resolve their target from the active window when omitted.
- /join accepts a comma-separated channel list and an optional key.
- /part with no argument parts the current channel.
- Typing in a status window with no target produces a clear error line, not silence.
- Argument errors print a usage line into the current window. Never crash, never
  silently drop input.

Input field behaviour:
- Per-window command history on Up/Down, capped, with the in-progress line preserved
  when you arrow away and back.
- Pasting multiple lines sends them as separate messages, in order.
- Enter on an empty line does nothing.

Tests: a table of input string + active window -> expected outbound IRC line(s) or
expected error. Pure logic, so it should be fast and exhaustive.

Do not: tab completion, aliases, scripting, or the paste-protection dialog.
```

---

## Prompt 10 — Status window, timestamps, and line rendering

```
Make the output actually look like mIRC, and close out stage 1.

- Per-network status window showing the connection log, MOTD, unhandled numerics,
  and — behind a toggle — raw wire traffic both directions with >>/<< markers. Every
  .raw event has somewhere to land.
- `/debug` following mIRC's semantics: `/debug <window>` streams the wire trace to a
  debug window, `/debug <file>` writes it to a file, `/debug off` stops it, and
  `/debug -i` includes the trace already sitting in the TraceBuffer ring, so you can
  turn it on *after* something has gone wrong and still see it. File output is
  redacted and the UI must say so — a user pasting a debug log into a bug report must
  not leak their NickServ password.
- A "Copy diagnostics" menu item putting the redacted ring buffer plus app/OS version
  on the clipboard.
- Timestamps: configurable strftime-style format, default [HH:mm:ss], dim, aligned so
  message text forms a clean left edge.
- Echo our own PRIVMSG/NOTICE/ACTION locally, since we have no echo-message yet. Mark
  self-echoed lines internally so stage 2 can suppress them when the capability is
  negotiated — a one-line enum case now saves an ugly bug later.
- Line kinds with distinct styling: normal message, own message, action, notice,
  join/part/quit, kick, mode, topic, nick change, server numeric, client error. Put
  the colors in one table so stage 2 theming has a single seam to replace. mIRC
  conventions: "*** Joins: nick (user@host)", "* nick does something" for actions,
  "-nick-" for notices.
- Nick column: sender rendered as <nick>, including the highest-ranking prefix char.
- Window titles and the sidebar reflect the active channel/network.

Acceptance — the stage 1 exit criteria, run end to end against Libera: connect over
TLS, join two channels, hold a conversation in both, send an action, send a PM, get
PMed, watch someone join and quit, use an unimplemented command via the raw
passthrough, disconnect cleanly, reconnect. Every one of those should look right and
leave the state consistent.

Then close out the stage: write a stage 1 retrospective as a decision entry in
BUILD-LOG.md, revise PLAN.md's stage 2 in light of what we learned, and prune
CLAUDE.md of anything the build proved unnecessary.

Do not: start stage 2 items. Formatting codes, multi-network, and logging are next.
```

---

## Logging and tracing — the design

Two facilities, deliberately not one.

**Diagnostic logging** is `os.Logger`: sparse, structured, no payloads. Free,
zero-dependency, integrates with Console.app and `log stream`, survives a crash.
Categories per module. This answers "what was the client doing."

**Wire tracing** is our own in-memory `TraceBuffer` ring, exported on demand. This
answers "what did the server actually send."

They are separate because the unified log is the wrong home for wire traffic. It
persists to disk outside our control, any admin process can read it, and `os_log`'s
privacy annotations are exactly the thing a "log everything" mode would turn off. A
ring buffer we own is bounded, disappears on quit, and only leaves the process when
the user explicitly exports it.

**Redaction happens on insert, not on export.** If credentials are only stripped at
export time, every intermediate state — a crash dump, a memory scrape, a forgotten
debug path — still holds them. Strip once at the boundary and the plaintext password
exists nowhere but the socket write itself. This is why `Redactor` is in prompt 2 with
its own tests rather than a formatting detail in prompt 10.

**Not building:** a log-routing framework, pluggable backends, custom level
hierarchies, log rotation, remote shipping. `os.Logger` plus one ring buffer plus one
pure redaction function. It grows only when something concrete demands it.

---

## Shaping notes

Things deliberately placed where they are, in case you want to move them:

- **Casemapping in prompt 3, not prompt 5.** Pure logic the parser-tests corpus
  already exercises, so it's cheap early. ISUPPORT in prompt 5 then only selects which
  mapping is active.
- **Multicast event stream in prompt 6.** A single `AsyncStream` works right up until
  logging and scripting both want the feed, and by then the fix touches everything.
- **The real scrollback view in prompt 7.** A placeholder means rewriting the app
  around it later.
- **Self-echo marking in prompt 10.** One enum case now; otherwise a duplicate-message
  bug that only appears on IRCv3 servers.
- **CAP/SASL absent from all ten.** Libera accepts unauthenticated connections, and
  CAP reshapes the registration state machine enough that a half-implementation is
  worse than none. It lands with stage 2's Authentication and IRCv3 capabilities
  items. (Referenced by name, not number — `PLAN.md` is a living roadmap whose
  numbering is expected to shift.)
- **The CI purity job is a rule, not just a cost saving.** IRCProtocol builds on
  Linux, which has no AppKit, no Network.framework and no Darwin `os.Logger`. If that
  module ever stops being pure, CI fails on the cheap runner. Prefer this shape of
  enforcement wherever one can be found.
