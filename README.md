<div align="center">

<!-- art:wordmark -->

```
    ██████╗ █████╗ ██████╗  █████╗ ██╗   ██╗ █████╗ ███╗   ██╗
   ██╔════╝██╔══██╗██╔══██╗██╔══██╗██║   ██║██╔══██╗████╗  ██║
   ██║     ███████║██████╔╝███████║██║   ██║███████║██╔██╗ ██║
   ██║     ██╔══██║██╔══██╗██╔══██║╚██╗ ██╔╝██╔══██║██║╚██╗██║
   ╚██████╗██║  ██║██║  ██║██║  ██║ ╚████╔╝ ██║  ██║██║ ╚████║
    ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝  ╚═╝╚═╝  ╚═══╝
```

<!-- /art:wordmark -->

**A native macOS IRC client loosely inspired by the good ol' days of mIRC.**

[![ci](https://github.com/Lacuna-Research/caravan/actions/workflows/ci.yml/badge.svg)](https://github.com/Lacuna-Research/caravan/actions/workflows/ci.yml)
[![docs](https://github.com/Lacuna-Research/caravan/actions/workflows/docs.yml/badge.svg)](https://github.com/Lacuna-Research/caravan/actions/workflows/docs.yml)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![BSD 3-Clause](https://img.shields.io/badge/licence-BSD--3--Clause-blue)](LICENSE)
[![dependencies 0](https://img.shields.io/badge/dependencies-0-2ea44f)](Package.swift)
[![stage 1: 11/11](https://img.shields.io/badge/stage%201-11%2F11%20prompts-2ea44f)](STAGE1-PROMPTS.md)
[![stage 2: 5/17](https://img.shields.io/badge/stage%202-5%2F17%20prompts-blue)](STAGE2-PROMPTS.md)

</div>

---

## What this is

mIRC got a great deal right in 1995 and most of it is still right. A tree of windows
you can actually navigate. A status window that shows the raw protocol when something
breaks. Scriptable everything. A client that treats IRC as a protocol rather than
hiding it behind a chat metaphor.

This is that client, rebuilt natively for macOS: Swift 6 with strict concurrency, a
SwiftUI shell with AppKit where AppKit is genuinely better, and **zero external
dependencies**.

> [!NOTE]
> **Early days.** The protocol layer is written and tested; the app currently launches
> to an empty window. Everything below marks what exists and what does not — see
> [Progress](#progress).

## Why another IRC client

- **The protocol is not hidden.** A status window shows raw traffic both directions,
  `/debug` streams it to a window or a file, and every unrecognized line still lands
  somewhere visible instead of being silently dropped.
- **Bouncer-first.** [soju](https://soju.im/) is a primary target, not an afterthought:
  `bouncer-networks` and `chathistory` land in stage 2, not stage 3.
- **Credentials are handled like credentials.** Redaction happens on insert into the
  trace buffer, never at export, so a password is never resident anywhere it could be
  scraped later. Secrets live in the macOS Keychain, never in a config file.
- **Nothing is written to the source tree.** Settings, logs and caches follow XDG
  paths — see [Where your data lives](#where-your-data-lives).
- **No dependency chain.** One SwiftPM package, four modules, nothing vendored but test
  fixtures.

### The name

After *Planet Caravan*, Black Sabbath, 1970. The app is not themed after the band and
will not be; the name simply fit. There may be an easter egg or two.

### Non-goals

Not a Slack replacement, not a "modern reimagining" of chat, not a bridge to five other
protocols. It is an IRC client.

## The shape of it

Where this is going — a mIRC-style layout with a network tree, header bar, nick list,
and a scrollback view that holds a hundred thousand lines without complaint.

<!-- art:mockup -->

```
┌─ Caravan ─────────────────────────────────────────────────────────────────────┐
│                         │ #caravan - a native macOS IRC client                │
│                         ├──────────────────────────────────────────────┬──────┤
│ * Libera.Chat           │ [12:04:17] *** Joins: alice (~a@example.net) │ @ops │
│   |- #caravan         * │ [12:04:22] <bob>   parser passes the corpus  │ @bob │
│   |- #swift             │ [12:04:31] <alice> all 66 cases?             │ +eve │
│   `- >NickServ          │ [12:04:36] * bob nods                        │  ann │
│                         │ [12:04:41] -NickServ- You are now identified │  joe │
│ * soju (bouncer)        │ [12:05:02] *** eve is now known as evelyn    │      │
│   |- #ops             o │                                              │      │
│   `- #dev               │                                              │      │
├─────────────────────────┴──────────────────────────────────────────────┴──────┤
│ [#caravan] > /msg alice thanks!                                               │
└───────────────────────────────────────────────────────────────────────────────┘
    * highlight    o activity
```

<!-- /art:mockup -->

*A mockup, not a screenshot. The window is currently empty — see Progress.*

## Architecture

Four modules, one app. Dependencies point one way only.

<!-- art:architecture -->

```
                      ┌───────────────────────────┐
                      │            App            │  SwiftUI shell
                      │   NSTextView scrollback   │  AppKit where it counts
                      └─────────────┬─────────────┘
                                    │
                      ┌─────────────▼─────────────┐
                      │        IRCSession         │  registration, ISUPPORT,
                      │   actor - event stream    │  state machine, events
                      └─────────────┬─────────────┘
                                    │
                      ┌─────────────▼─────────────┐
                      │       IRCTransport        │  NWConnection, TLS,
                      │   actor - line framing    │  send queue, reconnect
                      └─────────────┬─────────────┘
                                    │
                  ┌─────────────────┴───────────────────────┐
                  │                                         │
        ┌─────────▼─────────┐                   ┌───────────▼───────────┐
        │    Diagnostics    │                   │      IRCProtocol      │
        │ os.Logger         │                   │ parse - serialize     │
        │ Redactor          │                   │ IRCv3 tags - masks    │
        │ TraceBuffer       │                   │ casemapping           │
        │ Signposts         │                   │                       │
        └───────────────────┘                   └───────────────────────┘
             Darwin-only                         pure · builds on Linux
```

<!-- /art:architecture -->

`IRCProtocol` has no I/O, no Foundation, no Darwin APIs — nothing but the standard
library. **CI builds and runs its test suite on Linux**, so the moment someone reaches
for `AppKit` or `os.Logger` in there, a job fails. The rule is mechanical, not a
comment in a file.

## Progress

### Stage 2 — a mIRC daily driver

Seventeen prompts. [`STAGE2-PROMPTS.md`](STAGE2-PROMPTS.md) is authoritative; every
roadmap item below is attached to one of them.

| # | Prompt | Status |
|---|--------|--------|
| 1 | Formatting codes: rendering | ✅ done |
| 2 | The input field grows up | ✅ done |
| 3 | Capabilities and authentication | ✅ done |
| 4 | Multi-network, and the bouncer | ✅ done |
| 5 | Queries and CTCP | ✅ done |
| 6 | Activity and navigation at scale | ⬜ |
| 7 | Windows and chrome | ⬜ |
| 8 | Commands and modes | ⬜ |
| 9 | Things you can do to what is in the buffer | ⬜ |
| 10 | Options | ⬜ |
| 11 | The Dashboard and the server list | ⬜ |
| 12 | Logging | ⬜ |
| 13 | What deserves attention, and what deserves none | ⬜ |
| 14 | Presence | ⬜ |
| 15 | Channel list | ⬜ |
| 16 | Flood protection | ⬜ |
| 17 | Buffer utilities | ⬜ |

**Stage 2 is done when** you would use this instead of your current client.

### Stage 1 — connect, join, chat · complete

You can idle in a channel on Libera and hold a conversation.
[`STAGE1-PROMPTS.md`](STAGE1-PROMPTS.md) is the finished queue, kept for the record.

<details>
<summary>Eleven prompts, all landed</summary>

| # | Prompt | Status |
|---|--------|--------|
| 1 | Scaffold — package, Xcode project, CI | ✅ done |
| 2 | Diagnostics — logging, redaction, wire tracing | ✅ done |
| 3 | Message parser — IRCv3 tags, casemapping, masks | ✅ done |
| 4 | Transport — line framing, TLS, `NWConnection` | ✅ done |
| 5 | Registration and connection state machine | ✅ done |
| 6 | Typed event model | ✅ done |
| 7 | Minimal UI and the scrollback view | ✅ done |
| 8 | Channel and user state | ✅ done |
| 9 | Command line | ✅ done |
| 10 | Status window, timestamps, line rendering | ✅ done |
| 11 | Debug & Settings canvas | ✅ done |

</details>

## Roadmap

Full detail in [`PLAN.md`](PLAN.md).

<details>
<summary><b>Stage 1 — Basic</b> · connect, join, chat</summary>

- TLS connection, registration, `ISUPPORT`, `PING`/`PONG`, reconnect with backoff
- Full IRCv3 message parsing: tags with escaping, sources, numerics
- Casemapping (`ascii` / `rfc1459` / `strict-rfc1459`) and wildcard mask matching
- Channel and user state, nick list ordered by `PREFIX` rank
- `/join /part /msg /me /nick /quit /raw`, unknown commands passed straight through
- Status window with raw traffic, timestamps, mIRC-style event lines
- Debug & Settings canvas — `/debug` and the live wire trace, not shaped like a chat window
- Settings in a plain-text config you can edit by hand without the app clobbering it

</details>

<details>
<summary><b>Stage 2 — Intermediate</b> · a daily driver</summary>

- **Formatting** — bold, italic, underline, strikethrough, monospace, reverse, and the
  full 99-colour `^C` palette including the extended 16–98 range
- **Multi-window** — four activity states and highlight badges in the tree,
  next-unread and next-highlight keys, MRU Ctrl+Tab, a ⌘K quick-switcher, ⌘1–9
  bindings, detachable windows
- **Multi-network** — direct connections *and* soju's `bouncer-networks`, behind one
  sidebar model that does not care which is in play
- **Bouncer support** — `chathistory` backfill, de-duplicated against local logs
- Queries and CTCP (`VERSION` `PING` `TIME` `USERINFO` `CLIENTINFO` `FINGER` `ACTION`)
- Full command set — `/whois /whowas /who /mode /op /kick /ban /kickban /topic /invite
  /notice /away /list /names /ignore /oper /amsg /ame /ctcp /clear`
- Tab completion, mIRC-style cycling with a configurable suffix
- Mode tracking, ban/quiet/invex list dialogs, channel modes sheet
- Nick-list and channel context menus
- Options dialog — Connect, IRC, Display, Colors, Sounds, Logging, Mouse
- Server list with groups, autojoin, perform-on-connect, connect-on-startup
- Logging in mIRC's layout, log viewer, reload-last-N-lines on join
- Highlights, keyword and regex lists, per-event sounds, notifications, Dock badge
- Ignore list with wildcard masks and mIRC-style level flags
- Notify list via `MONITOR`, with `ISON` polling as fallback
- `/list` channel browser with filters, URL catcher, away system, flood protection
- **SASL** — `PLAIN`, `EXTERNAL` (CertFP), `SCRAM-SHA-256`; NickServ fallback
- **IRCv3** — `cap-notify` `multi-prefix` `away-notify` `account-notify` `extended-join`
  `userhost-in-names` `server-time` `message-tags` `echo-message` `batch` `chghost`
  `invite-notify` `setname` `standard-replies` `labeled-response`

</details>

<details>
<summary><b>Stage 3 — Advanced</b> · mIRC parity</summary>

- **DCC** — CHAT, SEND, GET with resume, passive/reverse DCC for NAT, a transfer
  manager, drag-and-drop onto a nick to send
- **Scripting in JavaScript**, not mIRC's language. Declarative aliases and popups for
  the one-liner cases, JavaScriptCore for real logic. A bare `JSContext` has no
  `require`, `fetch` or filesystem at all, so capabilities are granted rather than
  restricted — and Safari Web Inspector attaches for actual breakpoints.
- Identd, SOCKS5 and HTTP proxies, Tor
- Themes over stage 1's one format-table seam, F-key bindings, arbitrary shortcuts
- User levels and access lists, paste protection, spell check
- soju extras — `filehost`, `metadata`, `search`, `webpush`; ZNC compatibility quirks
- Full-text search across all logged history

</details>

<details>
<summary><b>Stage 4 — Polish and release</b></summary>

- Accessibility, localization, performance work on the scrollback pipeline
- Distribution as a Homebrew cask from our own tap; Developer ID signing and notarization
- **mIRC settings importer** — read `mirc.ini`, `servers.ini`, `remote.ini`
- Optional iCloud sync, optional iOS companion sharing the core modules

</details>

## Building

Requires **Xcode 26+** on macOS 15+.

```sh
git clone https://github.com/Lacuna-Research/caravan.git
cd caravan
make hooks          # install the pre-commit hook — once, after cloning
make all            # build, test, lint, docs check, app
```

| Target | What it does |
|---|---|
| `make build` | Compile the package |
| `make test` | Run the test suite |
| `make app` | Build the macOS app with `xcodebuild` |
| `make fmt` | Format with the toolchain's `swift format` |
| `make lint` | Format check, strict |
| `make check` | Documentation discipline |
| `make hooks` | Install the pre-commit hook |

`swift-testing` ships with Xcode rather than Command Line Tools, so `make test` and
`make app` need full Xcode. `make build`, `make lint` and `make check` work with CLT
alone.

## Where your data lives

Nothing is ever written inside the source tree — not even under a gitignored path.

| What | Where |
|---|---|
| Settings | `caravan.conf` in `$XDG_CONFIG_HOME/caravan/`, default `~/.config/caravan/` |
| Logs, scrollback | `$XDG_DATA_HOME/caravan/`, default `~/.local/share/caravan/` |
| Caches | `$XDG_CACHE_HOME/caravan/`, default `~/.cache/caravan/` |
| Passwords, client certs | **macOS Keychain — never a file** |

Config files are plain text and user-editable; treat their paths as public API. `caravan.conf`
is `key = value`, one per line, `#` for a comment. Your comments and any keys the app does
not recognise survive being written back, and a key that is not there takes its default —
so the file only ever holds what you actually changed.

## How this gets built

One prompt per branch, one PR, squash-merged once CI is green. `main` is protected:
four required checks, no force-pushes, admins not exempt.

The interesting part is that the project's own rules are **machine-checked**.
`Scripts/check-docs.sh` runs as a pre-commit hook and in CI, and fails on:

- `CLAUDE.md` over 100 lines — the cap forces pruning instead of accretion
- any edit to an existing `BUILD-LOG.md` line — it is append-only
- a `Sources/` change with no build-log entry
- a missing or malformed status line, or a progress badge that disagrees with it
- carry-forward notes that outlived the prompt they were addressed to
- undeclared SwiftPM dependencies

Two git hooks and a Stop hook cover what a diff can't see: no commits to `main`, no
pushing a `worktree-*` branch before renaming it, and no worktree left behind after
its PR merged.

| File | Purpose |
|---|---|
| [`PLAN.md`](PLAN.md) | Living roadmap across four stages |
| [`STAGE1-PROMPTS.md`](STAGE1-PROMPTS.md) | The ten stage-1 work units, authoritative |
| [`BUILD-LOG.md`](BUILD-LOG.md) | Append-only: decisions, deviations, surprises, measurements |
| [`CLAUDE.md`](CLAUDE.md) | Build standards and working method |

`BUILD-LOG.md` is the one worth reading. It records what was decided *and what was
rejected and why* — including the mistakes, which stay in the log alongside their
corrections rather than being quietly edited away.

## Licence

[BSD 3-Clause](LICENSE). Copyright (c) 2026, Lacuna Research.

The vendored `ircdocs/parser-tests` corpus is CC0-1.0 and imposes no conditions.

---

<div align="center">
<sub>Swift 6 · zero dependencies · <a href="BUILD-LOG.md">every decision written down</a></sub>
</div>
