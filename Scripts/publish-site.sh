#!/usr/bin/env bash
# Publish `www/` to the `gh-pages` branch, which is what GitHub Pages serves.
#
# `Scripts/check-docs.sh` fails when the two disagree, and its advice used to be a
# sentence — "copy www/* to the root of gh-pages" — which is a manual step described in
# prose and therefore a step done differently each time. This is that step.
#
# Plumbing rather than a checkout: the tree object pushed is *the same object* the check
# compares, so a successful publish cannot leave the two disagreeing. Nothing touches the
# working tree, so this is safe to run mid-branch.
#
# Usage:
#   ./Scripts/publish-site.sh            # publish www/ as of HEAD
#   ./Scripts/publish-site.sh --staged   # publish www/ as it is staged, before committing
#   ./Scripts/publish-site.sh <ref>      # publish www/ as of another ref
#   DRY_RUN=1 ./Scripts/publish-site.sh  # say what would happen, push nothing
#
# `--staged` is not a convenience, it is the normal case. `check-docs.sh` compares the
# *branch's* `www/` against what is published, and the pre-commit hook runs it — so a
# commit that changes the site cannot be made until the site is published, and the thing
# to publish is what is staged. The site therefore leads and `main` follows, which keeps
# the live page from ever being behind what a merged `main` claims.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ref=${1:-HEAD}
remote=${REMOTE:-origin}
dry_run=${DRY_RUN:-}

if [ "$ref" = "--staged" ]; then
	# `write-tree` turns the index into real tree objects, which is exactly what the
	# commit would have recorded — so publishing this cannot differ from the commit.
	source_tree=$(git ls-tree "$(git write-tree)" www | awk '{ print $3 }')
	described="staged, on $(git rev-parse --short HEAD)"
	if [ -z "$source_tree" ]; then
		printf 'No www/ directory in the index.\n' >&2
		exit 1
	fi
elif source_tree=$(git rev-parse --verify --quiet "$ref:www"); then
	described=$(git rev-parse --short "$ref")
else
	printf 'No www/ directory at %s.\n' "$ref" >&2
	exit 1
fi

git fetch --quiet "$remote" gh-pages || true

parent_args=()
if published=$(git rev-parse --verify --quiet "$remote/gh-pages"); then
	if [ "$(git rev-parse "$published^{tree}")" = "$source_tree" ]; then
		printf 'Already published: %s/gh-pages already serves www/ at %s.\n' \
			"$remote" "$described"
		exit 0
	fi
	parent_args=(-p "$published")
	printf 'Replacing the published site. Changing:\n'
	git diff --stat "$published^{tree}" "$source_tree" || true
else
	printf 'Creating %s/gh-pages from www/.\n' "$remote"
fi

# The subject names the commit the site came from, so anyone looking at `gh-pages` can
# tell which revision of the repository the live page corresponds to.
message="Publish www/ at $described"
commit=$(git commit-tree "$source_tree" "${parent_args[@]}" -m "$message")

if [ -n "$dry_run" ]; then
	printf '\nDRY_RUN set. Would push %s to %s/gh-pages as: %s\n' \
		"$(git rev-parse --short "$commit")" "$remote" "$message"
	exit 0
fi

# Not force: a fast-forward from the published commit is the only honest publish, and a
# rejection here means somebody else published in the meantime and this would erase it.
git push "$remote" "$commit:refs/heads/gh-pages"
printf '\nPublished. %s/gh-pages now serves www/ at %s.\n' "$remote" "$described"
