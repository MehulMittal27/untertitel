#!/usr/bin/env bash

# Builds the app into the one folder it is ever launched from, then checks that no other
# copy exists and that no older copy is still running. Use this instead of calling
# xcodebuild directly: a second build folder means a second copy of the app, and macOS
# will happily launch the stale one.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${UNTERTITEL_BUILD_DIR:-$HOME/untertitel-build}"
CONFIGURATION="Debug"
OTHER_CONFIGURATION="Release"

# --release builds the optimized app for daily use. It is signed the same way as the
# debug build (Config/Signing.xcconfig: your Apple Development team if
# Config/Signing.local.xcconfig names one, ad hoc otherwise) and is not notarized, so
# it is for this Mac only.
case "${1:-}" in
  "") ;;
  --release)
    CONFIGURATION="Release"
    OTHER_CONFIGURATION="Debug"
    ;;
  *)
    printf 'usage: %s [--release]\n' "$(basename "$0")" >&2
    exit 64
    ;;
esac

APP_NAME="Untertitel"
# Builds before the rename were called v2s.app and ran as the process "v2s".
LEGACY_APP_NAME="v2s"
APP_PATH="$BUILD_ROOT/Build/Products/$CONFIGURATION/$APP_NAME.app"
OTHER_APP_PATH="$BUILD_ROOT/Build/Products/$OTHER_CONFIGURATION/$APP_NAME.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$APP_NAME"
BUNDLE_ID="com.franklioxygen.v2s"

# SYMROOT and OBJROOT are given outright: a custom build location in Xcode's own
# settings would otherwise win over -derivedDataPath and put the app somewhere else.
xcodebuild \
  -project "$ROOT_DIR/v2s.xcodeproj" \
  -scheme v2s \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_ROOT" \
  SYMROOT="$BUILD_ROOT/Build/Products" \
  OBJROOT="$BUILD_ROOT/Build/Intermediates.noindex" \
  build

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  printf 'error: the build finished but %s is missing\n' "$APP_PATH" >&2
  exit 1
fi

# The debug and the release app are two copies of the same app. Only the one just
# built is kept, so there is still exactly one to launch.
if [[ -d "$OTHER_APP_PATH" ]]; then
  if pgrep -x "$APP_NAME" >/dev/null && [[ "$(ps -p "$(pgrep -x "$APP_NAME" | head -1)" -o comm= 2>/dev/null)" == "$OTHER_APP_PATH"/* ]]; then
    printf 'warning: the %s build is running, so it was not removed: quit it, then delete %s\n' \
      "$OTHER_CONFIGURATION" "$OTHER_APP_PATH" >&2
  else
    rm -rf "$OTHER_APP_PATH"
    printf 'Removed the %s build: %s\n' "$OTHER_CONFIGURATION" "$OTHER_APP_PATH"
  fi
fi

# The app as it was called before the rename, left in either configuration's folder.
for legacy_app in "$BUILD_ROOT"/Build/Products/{Debug,Release}/"$LEGACY_APP_NAME".app; do
  [[ -d "$legacy_app" ]] || continue
  if pgrep -x "$LEGACY_APP_NAME" >/dev/null; then
    printf 'warning: the old %s.app is running, so it was not removed: quit it, then delete %s\n' \
      "$LEGACY_APP_NAME" "$legacy_app" >&2
  else
    rm -rf "$legacy_app"
    printf 'Removed the old build from before the rename: %s\n' "$legacy_app"
  fi
done

status=0

# Any other copy of the app on this Mac is a stale build waiting to be launched.
while IFS= read -r other_app; do
  [[ -z "$other_app" || "$other_app" == "$APP_PATH" ]] && continue
  printf 'warning: another copy of the app exists, delete it: %s\n' "$other_app" >&2
  status=2
done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true)

# A copy that was started before this build still runs the old code. Debug builds keep
# the code in Untertitel.debug.dylib, so take the newest file next to the executable.
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
done < <(pgrep -x "$APP_NAME"; pgrep -x "$LEGACY_APP_NAME" || true)

printf '\nBuilt: %s\n' "$APP_PATH"
printf 'Launch with: open %q\n' "$APP_PATH"
exit "$status"
