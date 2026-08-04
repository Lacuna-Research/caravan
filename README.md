# irc-client

A native macOS IRC client modeled on mIRC. Swift 6, SwiftUI shell with AppKit where
it counts, no external dependencies.

Working name; not yet buildable — the package lands in prompt 1.

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

## Getting started

```sh
make hooks   # install the pre-commit hook — do this once after cloning
make check   # documentation discipline; also runs in CI
```

`make build`, `make test`, `make fmt` and `make lint` arrive with the package.

## Working method

One prompt per branch (`prompt-NN-slug`), one PR, squash-merged once CI is green.
`main` is protected server-side: `discipline` and `secrets` are required checks,
force-pushes and deletions are blocked, and admins are not exempt. The pre-commit
hook refuses `main` too, so you find out before pushing rather than after.

Every rule that can be checked by a machine is checked by `Scripts/check-docs.sh`
rather than trusted. See `CLAUDE.md` for the rest.
