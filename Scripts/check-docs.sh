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
TOTAL_PROMPTS=11
STAGE2_TOTAL_PROMPTS=18

cd "$(git rev-parse --show-toplevel)"

fail=0
err() {
	printf '  FAIL  %s\n' "$1" >&2
	fail=1
}
ok() { printf '  ok    %s\n' "$1"; }

# The website's copy of a stage's progress, checked against the status line it has to
# agree with. Called from the two status-line rules below, beside the README checks it
# mirrors — the site is a third place the same number is written down, and until now the
# only one nobody checked. It drifted to 4/17 against a `main` at 9/17.
#
# Reads the numbers out of the page rather than grepping for an expected string, so a
# failure can say what the page actually claims. Both are scoped to their own stage
# section: there are three, and an unscoped match would read stage 1's meter for stage 2.
site_progress() {
	local stage=$1 done_count=$2 total=$3
	[ -f www/index.html ] || return 0

	local shown expected
	shown=$(site_field "$stage" '[0-9]+/[0-9]+ prompts' 0 8)
	expected="$done_count/$total"
	if [ "$shown" = "$expected" ]; then
		ok "website stage $stage count matches ($expected)"
	else
		err "website stage $stage says '${shown:-nothing}' prompts, status line says $expected"
	fi

	# Derived, not eyeballed: one decimal place, which is the convention the page already
	# used, with a trailing `.0` trimmed so a finished stage reads `width:100%`.
	shown=$(site_field "$stage" 'width:[0-9.]+%' 6 7)
	expected=$(awk -v d="$done_count" -v t="$total" \
		'BEGIN { w = sprintf("%.1f", d * 100 / t); sub(/\.0$/, "", w); print w }')
	if [ "$shown" = "$expected" ]; then
		ok "website stage $stage meter matches (${expected}%)"
	else
		err "website stage $stage meter is '${shown:-missing}%', should be ${expected}%"
	fi
}

# The first match of `pattern` inside stage `want`'s section of the page, with `lead`
# characters trimmed from the front of the match and `trim` from its length.
site_field() {
	awk -v want="$1" -v pattern="$2" -v lead="$3" -v trim="$4" '
		match($0, /<h3>Stage [0-9]+ /) {
			stage = substr($0, RSTART + 10, RLENGTH - 11) + 0
		}
		stage == want && match($0, pattern) {
			print substr($0, RSTART + lead, RLENGTH - trim)
			exit
		}
	' www/index.html
}

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

	# Counted *within the stage 1 section*, not across the whole file: there are two
	# progress tables now, and an unscoped count would break stage 1's check the moment
	# a stage 2 prompt landed.
	done_rows=$(awk '/^### Stage 1/,/^## Roadmap/' README.md |
		grep -cE '^\| *[0-9]+ *\|.*\| *✅ done *\|' || true)
	if [ "$done_rows" -eq "$completed" ]; then
		ok "README progress table matches ($done_rows done)"
	else
		err "README progress table shows $done_rows done, status line says $completed"
	fi

	site_progress 1 "$completed" "$TOTAL_PROMPTS"

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

# 6b. Stage 2 carries the same two rules: a machine-readable status line, and no
# carry-forward note outliving the prompt it was addressed to. Deliberately *not* wired to
# the README badge — that badge tracks stage 1, which is finished and will not move again.
stage2=$(sed -n "s/^\*\*Status:\*\* \([0-9]\{1,\}\)\/$STAGE2_TOTAL_PROMPTS complete.*/\1/p" \
	STAGE2-PROMPTS.md | head -1)
if [ -z "$stage2" ]; then
	err "STAGE2-PROMPTS.md needs a line of exactly the form: **Status:** N/$STAGE2_TOTAL_PROMPTS complete. Next: prompt M."
else
	ok "STAGE2-PROMPTS.md status $stage2/$STAGE2_TOTAL_PROMPTS"

	badge2="stage%202-${stage2}%2F${STAGE2_TOTAL_PROMPTS}"
	if grep -qF "$badge2" README.md; then
		ok "README stage 2 badge matches ($stage2/$STAGE2_TOTAL_PROMPTS)"
	else
		err "README stage 2 badge disagrees with the status line; expected '$badge2'"
	fi

	# `[0-9]+[a-z]*` because a prompt may be split — 13a, 13b — which is the convention
	# `PLAN.md` already uses for items and which keeps every existing reference to
	# "prompt 13" true rather than renumbering everything after it.
	stage2_rows=$(awk '/^### Stage 2/,/^### Stage 1/' README.md |
		grep -cE '^\| *[0-9]+[a-z]* *\|.*\| *✅ done *\|' || true)
	if [ "$stage2_rows" -eq "$stage2" ]; then
		ok "README stage 2 table matches ($stage2_rows done)"
	else
		err "README stage 2 table shows $stage2_rows done, status line says $stage2"
	fi

	site_progress 2 "$stage2" "$STAGE2_TOTAL_PROMPTS"

	# **Position, not number.** The status line is a *count* of finished prompts, and a
	# split prompt breaks the coincidence that the two were the same: with 13a and 13b in
	# the queue, prompt "13" is the thirteenth and fourteenth things to do. Counting
	# headings in order compares like with like, and works whether or not anything is split.
	stale2=$(awk -v done="$stage2" '
		/^## Prompt [0-9]+[a-z]* / { position += 1; label = $3; next }
		/^\*\*Carry-forward\*\*/ { if (position > 0 && position <= done) printf "%s ", label }
		/^### Carry-forward/ { if (position > 0 && position <= done) printf "%s ", label }
	' STAGE2-PROMPTS.md)
	if [ -n "$stale2" ]; then
		err "Unconsumed carry-forward notes on completed stage 2 prompt(s): ${stale2% }"
	else
		ok "no stage 2 carry-forward notes outliving their prompt"
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

# 9. Every stage 2 item in PLAN.md must be attached to a prompt.
# A roadmap item nobody scheduled is an item that quietly does not get built.
if [ -f STAGE2-PROMPTS.md ]; then
	unattached=$(awk '/^## Stage 2/,/^## Stage 3/' PLAN.md |
		sed -n 's/^[0-9]\{1,\}[a-z]\{0,\}\. \*\*\([^*]*\)\*\*.*/\1/p' |
		sed 's/\.$//' |
		while IFS= read -r item; do
			grep -qF "$item" STAGE2-PROMPTS.md || printf '%s; ' "$item"
		done)
	if [ -n "$unattached" ]; then
		err "PLAN.md stage 2 items not attached to any prompt: $unattached"
	else
		ok "every stage 2 item is attached to a prompt"
	fi
fi

# 10. The published website must be what the repository says it is.
#
# `www/` here is the source; the `gh-pages` branch's root is what GitHub Pages actually
# serves. Nothing syncs them — a deploy workflow was considered and deliberately rejected
# — so without this the failure mode is silent and slow: someone edits the site, merges,
# and visitors keep seeing the old one until somebody happens to notice.
#
# Comparing tree object IDs rather than file contents: git has already hashed both sides,
# so equality is one comparison and covers additions, deletions and edits at once.
if [ -d www ]; then
	if git rev-parse --verify --quiet origin/gh-pages >/dev/null 2>&1; then
		# Which `www/` to judge depends on the mode. With a base ref this is CI, where
		# HEAD is the thing being merged. Without one this is the pre-commit hook, where
		# HEAD does not yet contain what is about to be committed — so the *index* is the
		# honest answer, and comparing HEAD there would pass a commit that breaks CI a
		# minute later.
		if [ $# -ge 1 ]; then
			source_tree=$(git rev-parse --verify --quiet "HEAD:www" || true)
		else
			source_tree=$(git ls-tree "$(git write-tree)" www | awk '{ print $3 }')
		fi
		published_tree=$(git rev-parse --verify --quiet "origin/gh-pages^{tree}" || true)
		if [ -z "$source_tree" ] || [ -z "$published_tree" ]; then
			err "could not read www/ or origin/gh-pages to compare them"
		elif [ "$source_tree" = "$published_tree" ]; then
			ok "www/ matches the published gh-pages branch"
		else
			err "www/ and the gh-pages branch differ; the live site is not what main says."
			printf '        run ./Scripts/publish-site.sh. Differences:\n' >&2
			diff \
				<(git ls-tree "$source_tree" | awk '{ print $4, $3 }' | sort) \
				<(git ls-tree "$published_tree" | awk '{ print $4, $3 }' | sort) \
				>&2 || true
		fi
	else
		# Not a failure: a shallow clone or a fresh one legitimately has no gh-pages ref,
		# and CI fetches it (docs.yml checks out with fetch-depth: 0). Saying so is the
		# point — a check that skips silently is a check nobody knows stopped running.
		printf '  skip  gh-pages not fetched; cannot compare the published site\n'
	fi
fi

if [ "$fail" -ne 0 ]; then
	printf '\nDocumentation discipline failed.\n' >&2
	exit 1
fi
printf 'All checks passed.\n'
