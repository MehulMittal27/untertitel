#!/usr/bin/env bash

# Builds the app into the one folder it is ever launched from, then checks that no other
# copy exists and that no older copy is still running. Use this instead of calling
# xcodebuild directly: a second build folder means a second v2s.app, and macOS will
# happily launch the stale one.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${UNTERTITEL_BUILD_DIR:-$HOME/untertitel-build}"
CONFIGURATION="Debug"
APP_PATH="$BUILD_ROOT/Build/Products/$CONFIGURATION/v2s.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/v2s"
BUNDLE_ID="com.franklioxygen.v2s"

xcodebuild \
  -project "$ROOT_DIR/v2s.xcodeproj" \
  -scheme v2s \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_ROOT" \
  build

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  printf 'error: the build finished but %s is missing\n' "$APP_PATH" >&2
  exit 1
fi

status=0

# Any other copy of the app on this Mac is a stale build waiting to be launched.
while IFS= read -r other_app; do
  [[ -z "$other_app" || "$other_app" == "$APP_PATH" ]] && continue
  printf 'warning: another copy of the app exists, delete it: %s\n' "$other_app" >&2
  status=2
done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true)

# A copy that was started before this build still runs the old code. Debug builds keep
# the code in v2s.debug.dylib, so take the newest file next to the executable.
built_at="$(stat -f '%m' "$APP_PATH/Contents/MacOS"/* | sort -n | tail -1)"
while IFS= read -r pid; do
  [[ -z "$pid" ]] && continue
  running_path="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  started="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed 's/ *$//')"
  started_at="$(date -j -f '%a %b %d %T %Y' "$started" '+%s' 2>/dev/null || echo 0)"
  if [[ "$running_path" != "$EXECUTABLE_PATH" ]]; then
    printf 'warning: a copy from another folder is running (pid %s): %s\n' "$pid" "$running_path" >&2
    status=2
  elif (( started_at < built_at )); then
    printf 'warning: the running app (pid %s) is older than this build: quit it and launch again\n' "$pid" >&2
    status=2
  fi
done < <(pgrep -x v2s || true)

printf '\nBuilt: %s\n' "$APP_PATH"
printf 'Launch with: open %q\n' "$APP_PATH"
exit "$status"
