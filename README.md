# irc-client

A native macOS IRC client modeled on mIRC. Swift 6, SwiftUI shell with AppKit where
it counts, no external dependencies.

Working name. The package builds; the app target does not exist yet.

## Where your data lives

Nothing is ever written inside the source tree.

| What | Where |
|---|---|
| Settings | `$XDG_CONFIG_HOME/irc-client/`, default `~/.config/irc-client/` |
| Logs, scrollback | `$XDG_DATA_HOME/irc-client/`, default `~/.local/share/irc-client/` |
| Caches | `$XDG_CACHE_HOME/irc-client/`, default `~/.cache/irc-client/` |
| Passwords, client certs | macOS Keychain — never a file |

## Layout

| File | Purpose |
|---|---|
| `PLAN.md` | Staged roadmap: basic → intermediate → advanced → polish |
| `STAGE1-PROMPTS.md` | The ten stage-1 work units, authoritative for scope and status |
| `BUILD-LOG.md` | Append-only history: decisions, deviations, surprises, measurements |
| `CLAUDE.md` | Build standards and working method |

## Modules

Four libraries, no external dependencies. `IRCProtocol` is pure — no I/O, no
Foundation networking, no Darwin APIs — and CI builds it alone on Linux so that
stays true mechanically rather than by review.

```
IRCProtocol   (no dependencies)      parsing, serialization, casemapping
Diagnostics   (no dependencies)      logging, redaction, wire tracing
IRCTransport  → Diagnostics, IRCProtocol      sockets, TLS, line framing
IRCSession    → all of the above     registration, state machine, events
```

## Getting started

```sh
make hooks   # install the pre-commit hook — once, after cloning
make build   # compile the package
make test    # requires full Xcode (see below)
make lint    # swift format, strict
make check   # documentation discipline
make all     # everything above except hooks
```

### Requires full Xcode

`swift-testing` and `XCTest` ship with Xcode, **not** with Command Line Tools, so
`make test` cannot run on a CLT-only machine. `make build`, `lint` and `check` all
work fine without it. CI runs the tests on its macOS runner either way.

The app target and `irc-client.xcodeproj` also need Xcode and do not exist yet.

## Running the app

Not yet possible — there is no app target. Tracked as a carry-forward note on
prompt 1 in `STAGE1-PROMPTS.md`.

## Working method

One prompt per branch (`prompt-NN-slug`), one PR, squash-merged once CI is green.
`main` is protected server-side: `discipline` and `secrets` are required checks,
force-pushes and deletions are blocked, and admins are not exempt. The pre-commit
hook refuses `main` too, so you find out before pushing rather than after.

Every rule that can be checked by a machine is checked by `Scripts/check-docs.sh`
rather than trusted. See `CLAUDE.md` for the rest.
