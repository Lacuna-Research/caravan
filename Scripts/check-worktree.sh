#!/usr/bin/env bash
# Detects a worktree that has outlived its prompt.
#
# Runs as a Stop hook, so it fires when a turn ends. The hard part is telling
# "just entered a worktree, about to work" from "finished, merged, still loitering".
# Both are clean trees, so cleanliness cannot separate them, and neither can
# commits-ahead-of-main: after a squash merge the local commits are not ancestors of
# main, so a finished branch still looks ahead.
#
# Two signals do work, either of which is conclusive:
#
#   1. Upstream gone — the branch was pushed and its remote counterpart deleted,
#      which in this workflow happens exactly on squash-merge.
#   2. Squash-landed — HEAD differs from the base branch but its *tree* is identical,
#      meaning our commits produced content that is already on main. A fresh worktree
#      has HEAD equal to the base, so it does not match.
#
# Signal 2 exists because signal 1 misses a push that did not set an upstream
# (`git push origin HEAD:name`), which is easy to do by accident.
#
# Deliberately silent in every other case — a Stop hook that cries wolf gets ignored,
# and this one can block a turn.
set -euo pipefail

case "$PWD" in
*/.claude/worktrees/*) ;;
*) exit 0 ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Uncommitted work means the prompt is still in progress.
[ -z "$(git status --porcelain 2>/dev/null)" ] || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
[ -n "$branch" ] && [ "$branch" != "HEAD" ] || exit 0

base=""
for candidate in origin/main origin/master; do
	if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
		base="$candidate"
		break
	fi
done

reason=""

# Signal 1: an upstream is configured but its remote-tracking ref no longer resolves.
#
# Read the config rather than asking `git rev-parse @{u}`: when the upstream ref is
# missing, rev-parse prints the literal string "@{u}" and exits 128 — byte-identical
# to the no-upstream-configured case, so its output cannot distinguish the two.
upstream_remote=$(git config --get "branch.$branch.remote" 2>/dev/null || echo "")
upstream_merge=$(git config --get "branch.$branch.merge" 2>/dev/null || echo "")
if [ -n "$upstream_remote" ] && [ -n "$upstream_merge" ]; then
	tracking="refs/remotes/$upstream_remote/${upstream_merge#refs/heads/}"
	if ! git rev-parse --verify --quiet "$tracking" >/dev/null 2>&1; then
		short="$upstream_remote/${upstream_merge#refs/heads/}"
		reason="its upstream \`$short\` no longer exists — the PR was merged and the remote branch deleted"
	fi
fi

# Signal 2: our commits are content-identical to the base branch.
if [ -z "$reason" ] && [ -n "$base" ]; then
	head_commit=$(git rev-parse HEAD)
	base_commit=$(git rev-parse "$base")
	if [ "$head_commit" != "$base_commit" ]; then
		head_tree=$(git rev-parse "HEAD^{tree}")
		base_tree=$(git rev-parse "$base^{tree}")
		if [ "$head_tree" = "$base_tree" ]; then
			reason="its content is already identical to \`$base\` — the work was squash-merged"
		fi
	fi
fi

[ -n "$reason" ] || exit 0

cat <<EOF
{"decision":"block","reason":"Stale worktree: you are still in \`$PWD\` on branch \`$branch\`, and $reason. Per CLAUDE.md step 7, a prompt ends at the repo root. Verify nothing unique remains (\`git status\`, \`git stash list\`, and that the branch adds no lines the base lacks), then call ExitWorktree with action \"remove\". If you are deliberately continuing to work here, say so and carry on."}
EOF
