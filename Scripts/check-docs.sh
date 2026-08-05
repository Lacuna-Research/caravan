#!/usr/bin/env bash
# Mechanical enforcement of the documentation discipline described in CLAUDE.md.
#
# Every rule here was previously a promise. A promise that a machine does not check
# is a promise that eventually is not kept.
#
# Usage:
#   ./Scripts/check-docs.sh <base-ref>   # CI: compare against a base branch
#   ./Scripts/check-docs.sh              # pre-commit: check staged changes
set -euo pipefail

CLAUDE_MAX_LINES=100
TOTAL_PROMPTS=10

cd "$(git rev-parse --show-toplevel)"

fail=0
err() {
	printf '  FAIL  %s\n' "$1" >&2
	fail=1
}
ok() { printf '  ok    %s\n' "$1"; }

if [ $# -ge 1 ]; then
	base="$1"
	scope="$base...HEAD"
	diff_names() { git diff --name-only "$base...HEAD"; }
	diff_file() { git diff "$base...HEAD" -- "$1"; }
else
	scope="staged changes"
	diff_names() { git diff --cached --name-only; }
	diff_file() { git diff --cached -- "$1"; }
fi

printf 'Documentation discipline (%s)\n' "$scope"

# 1. CLAUDE.md must stay short.
# Instruction files rot by accretion: rules get appended, never removed, until the
# file is long enough that nothing in it is read carefully. A hard cap forces the
# pruning that good intentions do not.
lines=$(wc -l <CLAUDE.md | tr -d ' ')
if [ "$lines" -gt "$CLAUDE_MAX_LINES" ]; then
	err "CLAUDE.md is $lines lines (cap $CLAUDE_MAX_LINES). Prune it. Do not raise the cap."
else
	ok "CLAUDE.md $lines/$CLAUDE_MAX_LINES lines"
fi

# 2. BUILD-LOG.md is append-only.
# A removed line is a rewrite of history. Corrections belong in a new entry.
if diff_file BUILD-LOG.md | grep -qE '^-[^-]'; then
	err "BUILD-LOG.md has removed or modified lines. It is append-only; correct in a new entry."
else
	ok "BUILD-LOG.md append-only"
fi

# 3. Code changes must carry a build-log entry.
if diff_names | grep -qE '^Sources/'; then
	if diff_names | grep -qx 'BUILD-LOG.md'; then
		ok "Sources/ change has a BUILD-LOG.md entry"
	else
		err "Sources/ changed but BUILD-LOG.md did not. Record deviations, surprises, measurements."
	fi
fi

# 4. Prompt status must exist and be machine-readable.
completed=$(sed -n "s/^\*\*Status:\*\* \([0-9]\{1,\}\)\/$TOTAL_PROMPTS complete.*/\1/p" \
	STAGE1-PROMPTS.md | head -1)
if [ -z "$completed" ]; then
	err "STAGE1-PROMPTS.md needs a line of exactly the form: **Status:** N/$TOTAL_PROMPTS complete. Next: prompt M."
else
	ok "STAGE1-PROMPTS.md status $completed/$TOTAL_PROMPTS"

	# 5. The README must agree with the status line.
	# A progress badge and a checklist are exactly the kind of thing that silently
	# goes stale, and a stale badge is worse than none — it is confidently wrong.
	badge="stage%201-${completed}%2F${TOTAL_PROMPTS}"
	if grep -qF "$badge" README.md; then
		ok "README progress badge matches ($completed/$TOTAL_PROMPTS)"
	else
		err "README progress badge disagrees with the status line; expected to contain '$badge'"
	fi

	done_rows=$(grep -cE '^\| *[0-9]+ *\|.*\| *✅ done *\|' README.md || true)
	if [ "$done_rows" -eq "$completed" ]; then
		ok "README progress table matches ($done_rows done)"
	else
		err "README progress table shows $done_rows done, status line says $completed"
	fi

	# 6. Carry-forward notes must not outlive the prompt they were addressed to.
	# A note that survives its prompt means the note was never consumed.
	stale=$(awk -v done="$completed" '
		/^## Prompt [0-9]+ / { n = $3 + 0; next }
		/^### Carry-forward/ { if (n > 0 && n <= done) printf "%d ", n }
	' STAGE1-PROMPTS.md)
	if [ -n "$stale" ]; then
		err "Unconsumed carry-forward notes on completed prompt(s): ${stale% }"
	else
		ok "no carry-forward notes outliving their prompt"
	fi
fi

# 7. README ASCII art must match its generator.
# Hand-editing box-drawn art is how it silently loses a column. The generator pads
# every cell to an exact width and places connectors by coordinate, so if the README
# disagrees with it, the README is wrong.
if command -v python3 >/dev/null 2>&1; then
	if python3 Scripts/render-readme-art.py --check >/dev/null 2>&1; then
		ok "README ASCII art matches its generator"
	else
		err "README ASCII art is out of date. Run: python3 Scripts/render-readme-art.py"
	fi
fi

# 8. No external SwiftPM dependencies without an explicit decision.
# Each dependency is attack surface and maintenance burden. Stage 1 needs none.
# Adding one means a decision entry in BUILD-LOG.md and an edit to this check.
if [ -f Package.swift ]; then
	if grep -qE '^[[:space:]]*\.package\(' Package.swift; then
		err "Package.swift declares an external dependency. Justify it in BUILD-LOG.md and amend this check."
	else
		ok "Package.swift has no external dependencies"
	fi
fi

if [ "$fail" -ne 0 ]; then
	printf '\nDocumentation discipline failed.\n' >&2
	exit 1
fi
printf 'All checks passed.\n'
