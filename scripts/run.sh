#!/usr/bin/env bash
# Build a Debug copy, then install and relaunch it from ~/Applications (never from DerivedData,
# so privacy grants stick). Extra arguments go to the app, e.g. -directory ~/code/my-app -harness codex -latest-session
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION=Debug exec scripts/install.sh "$@"
