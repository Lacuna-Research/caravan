# Stage 1 — The Nine Prompts

Each block is a self-contained prompt. They assume the previous ones are done and
committed. Every prompt has a **Do not** section — that's the scope fence that keeps
stage 2/3 work from leaking backward.

Standing rules (Swift 6 strict concurrency, macOS 15, swift-testing, zero warnings)
live in `CLAUDE.md` and load automatically — they don't need restating per prompt.
`CLAUDE.md` also carries the end-of-prompt obligations: update `BUILD-LOG.md`, raise
and consume carry-forward notes, push deferrals into `PLAN.md`.

### Carry-forward notes

When work on one prompt turns up something a later prompt needs to know, the note is
appended to **that prompt, in this file**, under a `### Carry-forward` heading:

```
### Carry-forward
- From prompt 3: NWConnection reports .ready before the TLS handshake completes,
  so don't start the registration timer here — wait for the first byte.
```

Notes live in the destination rather than a separate file because this file is
already re-read at the start of every prompt. There is no second place to remember to
check. A note is **deleted when the prompt that received it runs**, and the fact that
it was applied is recorded in `BUILD-LOG.md`. A carry-forward note that outlives its
prompt means the process failed, not that the note is still useful.

---

## Prompt 1 — Scaffold

```
Set up the project skeleton for a macOS IRC client.

Create:
- git init, with a Swift/macOS .gitignore
- A SwiftPM package `IRCClient` with library targets: Diagnostics, IRCProtocol,
  IRCTransport, IRCSession — plus matching test targets. Do not create modules we
  don't use yet.
- An Xcode app target `mirage` (working name) that depends on the three libraries,
  SwiftUI lifecycle, macOS 15 minimum, hardened runtime, network client entitlement.
- Package-level settings: Swift 6 language mode, StrictConcurrency=complete,
  warnings-as-errors off for now but zero warnings in practice.
- .swiftformat and .swiftlint.yml with a sane config; a Makefile or shell script
  with `fmt`, `lint`, `test`, `build` targets (set -euo pipefail).
- A README stub: what this is, how to build, how to run tests.

The Diagnostics module (keep it small — this is a thin layer, not a framework):
- `Log`: namespaced `os.Logger` instances, one per subsystem/category
  (transport, protocol, session, ui). Subsystem string from the bundle id.
- `Redactor`: a pure function that takes an outbound or inbound IRC line and returns
  it with credentials replaced by <redacted>. Must cover PASS, AUTHENTICATE, OPER,
  and PRIVMSG/NOTICE to NickServ matching identify/ghost/regain/release/setpass.
  Pure and table-tested — this is security-relevant code, not a convenience.
- `TraceBuffer`: a fixed-capacity in-memory ring of timestamped wire events
  (.inbound/.outbound, raw line, monotonic timestamp). Configurable capacity,
  default a few thousand entries. Thread-safe. Redaction applied on insert, not on
  read, so a credential is never resident in the buffer.
- `Signposts`: an OSSignposter for perf intervals; prompt 6 will use it.

The app should launch to a single empty window titled "mirage" with a
NavigationSplitView placeholder (empty sidebar, empty detail). Nothing else.

Acceptance: `swift build` and `swift test` both succeed with zero warnings, the app
launches showing the empty window, and the Redactor tests pass including negative
cases (a normal message mentioning the word "identify" must not be redacted).

Do not: write any IRC logic, networking, or UI beyond the empty split view. Do not
build log routing, pluggable backends, custom levels, or a log viewer UI.
```

**Note:** only Command Line Tools are installed. If you'd rather not install full Xcode,
say so in this prompt and I'll generate the `.app` bundle from SwiftPM with a
`codesign` script instead of an `.xcodeproj`.

---

## Prompt 2 — Message parser

```
Implement the IRCProtocol module: parsing and serializing IRC protocol messages.
Pure value types, zero I/O, no Foundation networking — this module must be
trivially testable and platform-agnostic.

Types:
- `IRCMessage`: tags, source, command, parameters
- `IRCTags`: ordered key -> String? (valueless tags are distinct from empty-valued),
  with the IRCv3 escape rules on parse and serialize: \: -> ;  \s -> space
  \\ -> \  \r -> CR  \n -> LF; a lone trailing backslash is dropped; unknown
  escapes drop the backslash.
- `IRCSource`: .server(String) or .user(nick:user:host:) — parse nick!user@host with
  either or both of user/host absent.
- `IRCCommand`: .verb(String) / .numeric(UInt16), preserving the 3-digit zero padding
  on serialize.
- Parameters: last param may be trailing (`:foo bar`). A param that is empty, starts
  with `:`, or contains a space MUST be serialized as trailing.

Also in this module (pure, and the parser-tests corpus covers them):
- `IRCCaseMapping`: .ascii, .rfc1459, .rfc1459Strict — with a `foldedCase(_:)` and a
  case-insensitive comparable `IRCNick`/`IRCChannelName` wrapper suitable for
  dictionary keys.
- Wildcard mask matching (`*`, `?`) for nick!user@host, casemapping-aware.

Limits: enforce 8191 bytes for the tag section and 512 bytes (including CRLF) for the
rest; expose these as constants and provide a `truncated(to:)` helper rather than
silently corrupting.

Tests: vendor the ircdocs/parser-tests YAML corpus (msg-split, msg-join,
userhost-split, mask-match) into Tests/Fixtures and drive table tests from it.
Add hand-written tests for the nasty cases: empty trailing, trailing that is just
":", tags with no value vs empty value, source with no user, 8-bit/invalid UTF-8
bytes in the trailing param.

Do not: implement ISUPPORT, CTCP, formatting codes, or anything that touches a socket.
```

---

## Prompt 3 — Transport

```
Implement IRCTransport: a connection that turns a socket into a stream of IRCMessage
and accepts messages to send. IRC semantics do not belong here.

- `LineFramer`: a pure struct that takes Data chunks and yields complete lines.
  Splits on \r\n but tolerates a bare \n. Handles a line split across arbitrarily
  many chunks. Lines longer than the protocol limit are dropped with a diagnostic
  rather than buffered forever. This type must be testable with zero networking —
  test it first and hard, it's where framing bugs hide.
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
- Use NWProtocolTLS for TLS. Self-signed acceptance goes through an explicit
  `sec_protocol_options_set_verify_block` — surface the certificate to the caller,
  do not blanket-trust.

Tracing: every line in and out goes to the Diagnostics TraceBuffer at the point of
serialization/framing — one call site each direction, so it is impossible for traffic
to bypass the trace. Use Log.transport for connection lifecycle at .info and errors
at .error. Do not log message payloads through os.Logger; payloads live in the
TraceBuffer only.

Tests: LineFramer unit tests including chunk boundaries mid-CRLF; an integration test
that stands up a local NWListener, has IRCConnection connect to it, and round-trips
messages both directions. Assert that a PASS line reaches the wire intact but appears
redacted in the TraceBuffer.

Do not: implement reconnect/backoff, PING/PONG, registration, or any numerics — those
are prompt 4. No CAP, no SASL, no proxies, no client certificates.
```

---

## Prompt 4 — Registration and connection state machine

```
Implement IRCSession's connection lifecycle on top of IRCTransport.

Registration sequence: optional PASS, then NICK, then USER <ident> 0 * :<realname>.
- On 433 (nick in use) during registration: try the alt nick, then append "_"
  progressively up to NICKLEN, then fail with a clear error.
- On 001 the session is registered; capture 002/003/004 server info.
- Parse every 005 ISUPPORT line into a `ServerCapabilities` struct with typed
  accessors, including at minimum: PREFIX (mode chars -> prefix chars, ordered by
  rank), CHANMODES (the four groups), CHANTYPES, CASEMAPPING, NETWORK, NICKLEN,
  CHANNELLEN, TOPICLEN, MODES, TARGMAX, STATUSMSG, MONITOR. Support token negation
  (-TOKEN) and unknown tokens (keep the raw string, don't discard).
  The parsed CASEMAPPING must drive the IRCCaseMapping used everywhere downstream.
- Reply to PING with PONG carrying the same token. Handle ERROR as a server-initiated
  close with the given reason.
- Idle detection: if nothing is received for N seconds send our own PING; if no
  response within M seconds, treat the connection as dead. Both configurable.
- Reconnect: exponential backoff with jitter and a ceiling, attempt counter, and a
  hard stop when the user disconnected deliberately. Reconnect must not fire while a
  connect is already in flight.

`SessionState` enum: .disconnected(reason), .connecting, .registering,
.connected(ServerInfo), .reconnecting(attempt: Int, nextAttemptIn: Duration).

Tests: build a scriptable fake IRC server (an NWListener that plays a canned
exchange and asserts what it receives). Cover: happy-path registration, nick
collision with fallback, PING/PONG, server ERROR, idle timeout, backoff schedule,
and that a deliberate disconnect does not reconnect.

Do not: track channels or users (prompt 7). No CAP negotiation, no SASL — those are
stage 2. No UI.
```

---

## Prompt 5 — Typed event model

```
Introduce IRCEvent as the single seam between IRCSession and everything above it,
and route all inbound traffic through it.

`enum IRCEvent: Sendable` with associated values, covering at least:
  .stateChanged(SessionState)
  .registered(ServerInfo)
  .message(target: Target, sender: IRCSource, text: String, kind: .privmsg/.notice,
           isAction: Bool)
  .joined / .parted / .quit / .nickChanged / .kicked / .topicChanged / .modeChanged
  .namesReply / .endOfNames
  .numeric(code: UInt16, params: [String])
  .clientError(String)   // our own diagnostics, e.g. "unknown command"

Hard rule: every inbound IRCMessage also emits `.raw(IRCMessage)` regardless of
whether it was recognized. Nothing the server sends may become invisible — that's
what makes the status window trustworthy and what makes debugging possible.

Delivery: the session needs multiple independent consumers (UI, logger, later
scripting), so a single AsyncStream is not enough. Implement a small multicast —
`events()` hands each caller its own AsyncStream, with a bounded buffer and a
documented drop policy for a slow consumer. Say explicitly in a comment what happens
when a consumer stalls.

Refactor prompt 4's internals to emit these events rather than exposing raw messages
directly. Keep a `Target` type that distinguishes channel from nick, casemapping-aware.

Tests: table-driven — given this raw line, assert exactly these events in this order.
Include a test that an unrecognized command still yields .raw and nothing else.

Do not: add channel/user state (prompt 7), and do not build UI.
```

---

## Prompt 6 — Minimal UI and the scrollback view

```
Build the first real UI. The scrollback view is the load-bearing component here —
build it properly now, because retrofitting it later means rewriting the app.

`MessageLogView`: an NSViewRepresentable wrapping NSTextView inside an NSScrollView.
- Non-editable, selectable, link detection on, no rich-text input.
- Append-only API: `append(_ lines: [AttributedString])` doing ONE batched
  textStorage mutation per flush (beginEditing/endEditing), not one per line.
  Coalesce appends on a short timer so a MOTD burst is a handful of mutations.
- Auto-scroll to bottom, but only when already pinned to the bottom. If the user has
  scrolled up, hold position and show a "jump to latest" affordance.
- Trim from the top past a configurable line cap so memory stays bounded.
- Benchmark it before you call it done: 50,000 lines appended, then scroll top to
  bottom. Report the numbers. Start with TextKit 2 (the default); if the numbers are
  bad, fall back to NSTextView(usingTextLayoutManager: false) and say why.

App structure:
- `@MainActor @Observable` view models consuming IRCSession's event stream.
- NavigationSplitView: sidebar lists the connection and its status window; detail is
  the scrollback view with a single-line input field beneath it.
- A Connect sheet: hostname, port, TLS toggle, nick, alt nick, ident, real name.
  Persist just the last-used values with @AppStorage as a stopgap.
- Connection status and errors visible in the UI, not just the console.

Acceptance: connect to irc.libera.chat:6697 over TLS, watch the full MOTD render in
the status window, and confirm scroll-lock works while it's still streaming.

Do not: multiple servers, channel windows, nick lists, formatting codes, logging,
or a preferences window.
```

---

## Prompt 7 — Channel and user state

```
Add channel membership tracking to IRCSession, and the channel window to the UI.

Model (inside the session actor, exposed as immutable snapshots):
- `Channel`: name, topic + who set it + when, members, own membership status.
- `Member`: nick, user, host if known, and the set of prefix modes held.
- All nick and channel keys use the casemapping from ISUPPORT — a server that
  says CASEMAPPING=rfc1459 must treat "Foo[]" and "foo{}" as the same nick.

Transitions to handle: JOIN (self vs. other — self-join creates the window),
PART, KICK, QUIT (remove the user from every channel they shared with us and report
per-channel), NICK (rename across all channels), 353/366 NAMES (parse ALL leading
prefix characters per nick, not just the first — multi-prefix comes in stage 2 but
the parser should already be correct), 332/333 topic, 331 no topic, 324 channel modes,
and the join-failure numerics (471/473/474/475/476/477) surfaced as usable errors.

Nick list ordering: by prefix rank as declared by ISUPPORT PREFIX (not a hardcoded
@%+ list), then casemapped alphabetical.

UI:
- Sidebar gains channels nested under their network.
- Channel window: topic bar across the top, scrollback, nick list pane on the right
  with a member count, input field below.
- Joins/parts/quits/kicks/nick changes/mode changes render as distinct event lines.

Tests: state-transition tests driven by scripted server output, including the
awkward ones — QUIT removing a user from three channels at once, a nick change
colliding with casemapping, NAMES arriving in several batches.

Do not: context menus, mode dialogs, ban lists, or user-facing mode editing.
```

---

## Prompt 8 — Command line

```
Implement the input command layer.

Parsing: a leading "/" introduces a command; "//" sends a literal leading slash.
Everything else is a message to the current window's target.

Commands for this stage:
  /join /part /msg /query /me /notice /nick /topic /quit
  /server /connect /disconnect
  /raw (alias /quote)
Unknown /commands are uppercased and sent to the server verbatim — that's how mIRC
behaves and it makes the client immediately useful for anything we haven't wired up.

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
expected error. This is pure logic, so it should be fast and exhaustive.

Do not: tab completion, aliases, scripting, or the paste-protection dialog.
```

---

## Prompt 9 — Status window, timestamps, and line rendering

```
Make the output actually look like mIRC, and close out stage 1.

- Per-network status window showing the connection log, MOTD, unhandled numerics,
  and — behind a toggle — the raw wire traffic in both directions with >>/<< markers.
  Every .raw event has somewhere to land.
- `/debug` following mIRC's semantics: `/debug <window>` streams the wire trace to a
  debug window, `/debug <file>` writes it to a file, `/debug off` stops it, and
  `/debug -i` includes the trace already sitting in the TraceBuffer ring so you can
  turn it on *after* something has gone wrong and still see it. File output is
  redacted, and the UI must say so — a user pasting a debug log into a bug report
  should not be leaking their NickServ password.
- A "Copy diagnostics" menu item that puts the redacted ring buffer plus app/OS
  version on the clipboard.
- Timestamps: configurable strftime-style format, default [HH:mm:ss], rendered in a
  dim color, aligned so message text forms a clean left edge.
- Echo our own PRIVMSG/NOTICE/ACTION locally, since we don't have echo-message yet.
  Mark self-echoed lines internally so stage 2 can suppress them when the capability
  is negotiated — a one-line enum case now saves an ugly bug later.
- Line kinds with distinct styling: normal message, own message, action, notice,
  join/part/quit, kick, mode, topic, nick change, server numeric, client error.
  Put the colors in one table so the stage 2 theming work has a single seam to
  replace. mIRC conventions: "*** Joins: nick (user@host)", "* nick does something"
  for actions, "-nick-" for notices.
- Nick column: sender rendered as <nick> for messages, with the highest-ranking
  prefix character included.
- Window titles and the sidebar reflect the active channel/network.

Acceptance — the stage 1 exit criteria, run end to end against Libera:
connect over TLS, join two channels, hold a conversation in both, send an action,
send a PM, get PMed, watch someone join and quit, use an unimplemented command via
the raw passthrough, disconnect cleanly, and reconnect. Every one of those should
look right and leave the state consistent.

Then write STAGE1-NOTES.md: what got deferred, what surprised us, and anything that
should change in the stage 2 plan.

Do not: start stage 2 items. Formatting codes, multi-network, and logging are next.
```

---

## Logging and tracing — the design

Two facilities, deliberately not one.

**Diagnostic logging** is `os.Logger`: sparse, structured, no payloads. Free,
zero-dependency, integrates with Console.app and `log stream`, and survives a crash.
Categories per module. This answers "what was the client doing."

**Wire tracing** is our own in-memory `TraceBuffer` ring, exported on demand. This
answers "what did the server actually send."

They are separate because the unified log is the wrong home for wire traffic. It
persists to disk outside our control, any admin process can read it, and `os_log`'s
privacy annotations are exactly the thing a "log everything" mode would be turning
off. A ring buffer we own is bounded, disappears on quit, and only leaves the process
when the user explicitly exports it.

**Redaction happens on insert, not on export.** If credentials are only stripped at
export time, then every intermediate state — a crash dump, a memory scrape, a
forgotten debug path — still holds them. Strip once, at the boundary, and the
plaintext password never exists anywhere but the socket write itself. This is why
`Redactor` is in prompt 1 with its own tests rather than being a formatting detail
in prompt 9.

**What we are not building:** a log-routing framework, pluggable backends, custom
level hierarchies, log rotation, or remote log shipping. `os.Logger` plus one ring
buffer plus one pure redaction function. If it grows past that, it should be because
something concrete demanded it.

---

## Shaping notes

Things I deliberately put where I put them, in case you want to move them:

- **Casemapping in prompt 2, not prompt 4.** It's pure logic and the parser-tests
  corpus already exercises mask matching, so it's cheap to get right early. ISUPPORT
  in prompt 4 then just selects which mapping is active.
- **The multicast event stream in prompt 5.** A single `AsyncStream` works right up
  until logging and scripting both want the feed, and by then the fix touches
  everything. Cheaper now.
- **The real scrollback view in prompt 6.** A placeholder here means rewriting the
  app around it later.
- **Self-echo marking in prompt 9.** One enum case now; a duplicate-message bug that
  only appears on IRCv3 servers if we skip it.
- **CAP/SASL deliberately absent from all nine.** Libera accepts unauthenticated
  connections, so stage 1 doesn't need it, and CAP negotiation changes the shape of
  the registration state machine enough that doing it half-way is worse than not
  doing it. It's stage 2 item 28/29.
