#!/usr/bin/env bash
# Everything CI would run: package tests, then the app build.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
# The classifier's Jev package is optional (a private repo); without it, skip the Node checks.
if [ -d health/node_modules/@prisma-labs/jev ]; then pnpm -C health -s check; fi
scripts/build.sh >/dev/null
echo "ok"
