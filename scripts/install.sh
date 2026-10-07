#!/usr/bin/env bash
# Build, sign with a stable identity (scripts/sign.sh), install to ~/Applications and launch it.
# One app at one path keeps macOS privacy grants. Extra arguments go to the app.
# CONFIGURATION defaults to Release; scripts/run.sh installs a Debug build the same way.
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(CONFIGURATION="${CONFIGURATION:-Release}" scripts/build.sh | tail -1)
dest="$HOME/Applications/Context Lens.app"
scripts/sign.sh "$app"
# Quit only this copy; a Homebrew copy in /Applications keeps running.
pkill -f "^$dest/Contents/MacOS/Context Lens" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$dest"
ditto "$app" "$dest"
if [ -d "/Applications/Context Lens.app" ]; then
  echo "note: /Applications/Context Lens.app also exists (Homebrew?); remove one so there is one app" >&2
fi
link="$HOME/.local/bin/context-lens"
if [ -L "$link" ]; then ln -sf "$dest/Contents/MacOS/context-lens" "$link"; fi
open -n "$dest" --args "$@"
echo "$dest"
