#!/usr/bin/env bash
# Build, then relaunch the app. Extra arguments go to the app, e.g. -directory ~/code/my-app -harness codex -latest-session
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(scripts/build.sh | tail -1)
pkill -x "Context Lens" 2>/dev/null || true
open -n "$app" --args "$@"
