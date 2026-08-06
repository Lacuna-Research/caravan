#!/usr/bin/env bash
# The worktree inventory: what exists, whether it is still alive, and what is safe to
# remove.
#
# `Scripts/check-worktree.sh` answers "am I loitering in a worktree that is finished?" —
# it only fires from *inside* one. This answers the question you cannot ask from there:
# what is lying around the repository as a whole. Worktrees accumulate silently, and a
# forgotten one is a branch you stop thinking about with work in it.
#
# **Removable means provably merged, never merely tidy.** Two conclusive signals, the same
# ones `check-worktree.sh` uses:
#
#   1. Upstream gone — the branch was pushed and its remote counterpart deleted, which in
#      this workflow happens exactly on squash-merge.
#   2. Squash-landed — HEAD differs from the base branch but its *tree* is identical, so
#      the content is already on main.
#
# Anything else is left alone and merely listed. That matters because not every worktree
# here is the assistant's: design conversations live on their own long-running branches,
# and a tool that treated "not merged yet" as "probably rubbish" would eventually delete
# somebody's unfinished thinking.
#
# Usage:
#   Scripts/worktrees.sh            # inventory
#   Scripts/worktrees.sh --prune    # remove the provably-merged ones
#   Scripts/worktrees.sh --hook     # Stop-hook JSON, silent unless something is removable
set -euo pipefail

# The *main* checkout, which is the first entry `git worktree list` prints — not
# `--show-toplevel`, which answers with whichever worktree you happen to be standing in
# and would therefore exclude the wrong one from the inventory.
MAIN_ROOT=$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)

# Where we were *called* from, captured before the `cd` below moves us. The hook mode
# needs it to tell "standing at the root" from "standing in a worktree", and reading $PWD
# after the cd makes that test answer yes always — which had the hook firing from inside a
# worktree, on top of check-worktree.sh, about the worktree being worked in.
CALLED_FROM="$PWD"
cd "$MAIN_ROOT"

mode="${1:-list}"

base=""
for candidate in origin/main origin/master; do
	if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
		base="$candidate"
		break
	fi
done

# Verdict for one worktree path. Prints one of:
#   working    uncommitted changes — in use, never touched
#   merged     upstream is gone; the PR landed and the remote branch was deleted
#   landed     content is identical to the base branch; squash-merged
#   fresh      no commits of its own yet
#   ahead:N    N commits not on the base branch — real, unfinished work
verdict() {
	local path="$1" branch upstream_remote upstream_merge tracking head_commit base_commit

	[ -z "$(git -C "$path" status --porcelain 2>/dev/null)" ] || {
		echo "working"
		return
	}

	branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
	if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
		echo "fresh"
		return
	fi

	# Read the config rather than `rev-parse @{u}`: with the upstream ref missing,
	# rev-parse's output is byte-identical to the no-upstream-configured case.
	upstream_remote=$(git -C "$path" config --get "branch.$branch.remote" 2>/dev/null || echo "")
	upstream_merge=$(git -C "$path" config --get "branch.$branch.merge" 2>/dev/null || echo "")
	if [ -n "$upstream_remote" ] && [ -n "$upstream_merge" ]; then
		tracking="refs/remotes/$upstream_remote/${upstream_merge#refs/heads/}"
		if ! git -C "$path" rev-parse --verify --quiet "$tracking" >/dev/null 2>&1; then
			echo "merged"
			return
		fi
	fi

	if [ -n "$base" ]; then
		head_commit=$(git -C "$path" rev-parse HEAD)
		base_commit=$(git -C "$path" rev-parse "$base")
		if [ "$head_commit" = "$base_commit" ]; then
			echo "fresh"
			return
		fi
		if [ "$(git -C "$path" rev-parse 'HEAD^{tree}')" = "$(git -C "$path" rev-parse "$base^{tree}")" ]; then
			echo "landed"
			return
		fi
		echo "ahead:$(git -C "$path" rev-list --count "$base..HEAD" 2>/dev/null || echo '?')"
		return
	fi
	echo "fresh"
}

removable() { [ "$1" = "merged" ] || [ "$1" = "landed" ]; }

# Every worktree except the main checkout itself.
paths() {
	git worktree list --porcelain |
		sed -n 's/^worktree //p' |
		while IFS= read -r path; do
			[ "$path" = "$MAIN_ROOT" ] || printf '%s\n' "$path"
		done
}

case "$mode" in
list)
	found=0
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		found=1
		state=$(verdict "$path")
		branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
		if removable "$state"; then
			printf '  removable  %-34s %s (%s)\n' "$(basename "$path")" "$branch" "$state"
		else
			printf '  keep       %-34s %s (%s)\n' "$(basename "$path")" "$branch" "$state"
		fi
	done < <(paths)
	[ "$found" -eq 1 ] || echo "  no worktrees"
	;;

prune)
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		state=$(verdict "$path")
		removable "$state" || continue
		branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
		# Order matters: the worktree has to go first, or deleting the branch fails
		# with "used by worktree". This is the same ordering `gh pr merge
		# --delete-branch` gets wrong, which is why landing a PR keeps reporting a
		# failure after it has already merged.
		git worktree remove "$path" --force
		if [ -n "$branch" ]; then
			git branch -D "$branch" >/dev/null 2>&1 || true
		fi
		echo "  removed    $(basename "$path") ($state)"
	done < <(paths)
	git worktree prune
	;;

--hook | hook)
	# Only from the main checkout: inside a worktree, check-worktree.sh already has
	# the floor and two hooks arguing about the same turn is how a hook gets ignored.
	[ "$CALLED_FROM" = "$MAIN_ROOT" ] || exit 0
	stale=""
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		state=$(verdict "$path")
		removable "$state" && stale="$stale\`$(basename "$path")\` ($state) "
	done < <(paths)
	[ -n "$stale" ] || exit 0
	cat <<EOF
{"decision":"block","reason":"Merged worktree still on disk: ${stale% }. Its PR landed, so nothing unique remains in it. Run \`make worktrees-prune\` to remove it and delete its branch, then carry on. If you are keeping it deliberately, say so."}
EOF
	;;

*)
	echo "usage: $0 [--prune|--hook]" >&2
	exit 2
	;;
esac
