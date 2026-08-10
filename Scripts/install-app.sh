#!/usr/bin/env bash
# Build Caravan and put it in /Applications, so the thing you double-click is the thing
# this checkout builds.
#
# **Release, not Debug.** `make app` builds Debug because that is what an acceptance run
# wants — assertions live, symbols fat. What somebody actually uses all day should be
# optimised, so this configuration differs from `make app` deliberately.
#
# **The product path is asked for, never written down.** `DerivedData` is keyed on the
# project's path, so every worktree gets its own folder and a hard-coded path installs
# whichever checkout happened to build there last. `BUILD-LOG.md` records that mistake four
# times, twice as a "defect" in code that had already been fixed.
#
# Usage:
#   ./Scripts/install-app.sh                 # build Release and install to /Applications
#   DESTINATION=~/Applications ./Scripts/install-app.sh
#   SKIP_BUILD=1 ./Scripts/install-app.sh    # install what is already built
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

configuration=${CONFIGURATION:-Release}
destination=${DESTINATION:-/Applications}

if [ -z "${SKIP_BUILD:-}" ]; then
	xcodebuild -project Caravan.xcodeproj -scheme Caravan \
		-configuration "$configuration" build >/dev/null
fi

settings=$(xcodebuild -project Caravan.xcodeproj -scheme Caravan \
	-configuration "$configuration" -showBuildSettings 2>/dev/null)
products=$(printf '%s\n' "$settings" | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)
name=$(printf '%s\n' "$settings" | sed -n 's/^ *FULL_PRODUCT_NAME = //p' | head -1)
built="$products/$name"

if [ ! -d "$built" ]; then
	printf 'Not built: %s\n' "$built" >&2
	exit 1
fi

if [ ! -w "$destination" ]; then
	printf '%s is not writable. Set DESTINATION=~/Applications to install elsewhere.\n' \
		"$destination" >&2
	exit 1
fi

# **Said before it happens, not after.** Replacing the bundle under a running copy leaves
# that copy running the old code, which is a confusing way to discover a fix did not land.
if pgrep -f "$destination/$name/Contents/MacOS/${name%.app}" >/dev/null 2>&1; then
	printf 'Note: %s is running. Quit and reopen it to pick this build up.\n' "${name%.app}"
fi

# **Nothing here deletes a path it was handed.** Both removals below name a directory this
# script created moments earlier, under a prefix of its own, and `${var:?}` makes an empty
# expansion abort rather than widen. `shellcheck` asks for exactly this, and it is asking
# about the case where `$destination` or `$name` came back empty and `rm -rf` met `/`.
: "${destination:?}" "${name:?}"

# Copy in beside the target and swap, so an interrupted copy cannot leave a half-written
# bundle where a working one used to be.
staging="${destination:?}/.${name:?}.incoming.$$"
previous="${destination:?}/.${name:?}.previous.$$"
trap 'rm -rf "${staging:?}" "${previous:?}"' EXIT

ditto "$built" "$staging"
if [ -d "$destination/$name" ]; then
	# Moved aside rather than deleted in place: if the swap fails, the working copy is
	# still on disk under a name the trap will clean up.
	mv "$destination/$name" "$previous"
fi
mv "$staging" "$destination/$name"

executable="$destination/$name/Contents/MacOS/${name%.app}"
printf 'installed %s\n' "$destination/$name"
printf 'from      %s\n' "$built"
printf 'built     %s\n' "$(date -r "$executable" '+%Y-%m-%d %H:%M:%S')"
printf 'commit    %s\n' "$(git rev-parse --short HEAD)$(git diff --quiet || echo ' (dirty)')"
