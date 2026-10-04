#!/usr/bin/env bash
# Build a Release copy, install it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(CONFIGURATION=Release scripts/build.sh | tail -1)
dest="$HOME/Applications/Context Lens.app"
pkill -x "Context Lens" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$dest"
ditto "$app" "$dest"
# Earlier installs went to /Applications. Remove that copy so there is one app, and point the
# command line tool link at the new one.
rm -rf "/Applications/Context Lens.app"
link="$HOME/.local/bin/context-lens"
if [ -L "$link" ]; then ln -sf "$dest/Contents/MacOS/context-lens" "$link"; fi
open "$dest"
echo "$dest"
