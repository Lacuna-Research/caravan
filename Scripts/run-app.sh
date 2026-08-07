#!/usr/bin/env bash
# Launch the app that was just built from *this* checkout, against a throwaway config.
#
# Two recurring defects, made impossible rather than remembered:
#
# 1. **The wrong binary.** `DerivedData` is keyed on the project's path, so every worktree
#    gets its own folder — and a hard-coded path launches whichever checkout happened to
#    build there last. `BUILD-LOG.md` records this four times now, twice with a "defect"
#    that had already been fixed in the source being read. So the path is asked for rather
#    than written down.
# 2. **Writing into the developer's own settings.** `CLAUDE.md` requires a live run under
#    its own `XDG_CONFIG_HOME`, and an inline environment assignment is not enough — the
#    app has to be launched from a script that exports them first.
#
# Usage:
#   ./Scripts/run-app.sh                 # a fresh throwaway profile under $TMPDIR
#   ./Scripts/run-app.sh <profile-dir>   # reuse one, so a run can be repeated
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

profile=${1:-}
if [ -z "$profile" ]; then
	profile=$(mktemp -d "${TMPDIR:-/tmp}/caravan-run.XXXXXX")
fi
mkdir -p "$profile/config/caravan" "$profile/data/caravan" "$profile/cache/caravan"

settings=$(xcodebuild -project Caravan.xcodeproj -scheme Caravan \
	-configuration Debug -showBuildSettings 2>/dev/null)
products=$(printf '%s\n' "$settings" | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)
name=$(printf '%s\n' "$settings" | sed -n 's/^ *FULL_PRODUCT_NAME = //p' | head -1)
app="$products/$name"
executable="$app/Contents/MacOS/${name%.app}"

if [ ! -x "$executable" ]; then
	printf 'Not built yet: %s\n  run: make app\n' "$app" >&2
	exit 1
fi

# Said out loud every time. The whole point is that the reader can see *which* binary and
# *which* profile before they start trusting what the window shows them.
#
# **The executable's timestamp, not the bundle's.** A rebuild replaces the binary inside
# `Contents/MacOS` without touching the `.app` directory's own mtime, so a "built" line
# reading the bundle sits still across rebuilds — which is the same lie as a hard-coded
# path, told more convincingly. Caught by this script reporting 17:40 for a binary written
# at 17:51.
printf 'app     %s\n' "$app"
printf 'built   %s\n' "$(date -r "$executable" '+%Y-%m-%d %H:%M:%S')"
printf 'profile %s\n\n' "$profile"

export XDG_CONFIG_HOME="$profile/config"
export XDG_DATA_HOME="$profile/data"
export XDG_CACHE_HOME="$profile/cache"
exec "$executable"
