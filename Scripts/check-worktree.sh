#!/usr/bin/env bash
# Detects a worktree that has outlived its prompt.
#
# Runs as a Stop hook, so it fires when a turn ends. The hard part is telling
# "just entered a worktree, about to work" from "finished, merged, still loitering".
# Both are clean trees. The discriminator is the upstream branch: this only fires
# once the branch has been pushed AND its remote counterpart has been deleted, which
# in this workflow happens exactly when the PR is squash-merged.
#
# Deliberately silent in every other case — a Stop hook that cries wolf gets ignored,
# and this one can block a turn.
set -euo pipefail

# Nothing to say unless we are inside a worktree under .claude/worktrees/.
case "$PWD" in
*/.claude/worktrees/*) ;;
*) exit 0 ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Uncommitted work means the prompt is still in progress.
[ -z "$(git status --porcelain 2>/dev/null)" ] || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
[ -n "$branch" ] && [ "$branch" != "HEAD" ] || exit 0

# No upstream means nothing has been pushed yet — work in progress, not leftovers.
upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || echo "")
[ -n "$upstream" ] || exit 0

# Upstream still exists means the PR has not been merged-and-deleted yet.
if git rev-parse --verify --quiet "$upstream" >/dev/null 2>&1; then
	exit 0
fi

# Pushed, remote branch gone, tree clean: the work has landed and this worktree is
# leftovers. Block the turn so the agent is told rather than the user noticing.
cat <<EOF
{"decision":"block","reason":"Stale worktree: you are still in \`$PWD\` on branch \`$branch\`, whose upstream \`$upstream\` no longer exists — the PR was merged and the remote branch deleted. Per CLAUDE.md step 7, a prompt ends at the repo root. Verify nothing unique remains (\`git status\`, \`git stash list\`, and that the branch adds no lines main lacks), then call ExitWorktree with action \"remove\". If you are deliberately continuing to work here, say so and carry on."}
EOF
