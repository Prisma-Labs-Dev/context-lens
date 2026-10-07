#!/usr/bin/env bash
# Sign a built app with a stable identity, so macOS privacy grants (Full Disk Access and the
# like) survive rebuilds. macOS keys those grants on the code signature: an ad hoc signature
# changes with every build, and each build would ask again.
#
# Uses $CONTEXT_LENS_SIGN_IDENTITY when set, else the first "Apple Development" identity in the
# keychain, else ad hoc.
set -euo pipefail
app="$1"
identity="${CONTEXT_LENS_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /{print $2; exit}')
fi
if [ -z "$identity" ]; then
  identity="-"
  echo "note: no Apple Development identity; signing ad hoc, so privacy grants reset on every build" >&2
fi
# Nested code first (the CLI, debug dylibs), then the app.
find "$app/Contents/MacOS" "$app/Contents/Frameworks" -type f -perm -u+x -o -name '*.dylib' 2>/dev/null |
  grep -v "/Contents/MacOS/Context Lens$" |
  while read -r f; do codesign --force --sign "$identity" --timestamp=none "$f"; done
codesign --force --sign "$identity" --timestamp=none "$app"
