#!/usr/bin/env bash
# Generate the Xcode project and build the app into ./build. Prints the .app path.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcode-disk-guard >/dev/null && xcode-disk-guard preflight --protect "$PWD" >/dev/null
xcodegen generate --quiet
xcodebuild -project ContextLens.xcodeproj -scheme ContextLens -configuration "${CONFIGURATION:-Debug}" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build -quiet
echo "$PWD/build/DerivedData/Build/Products/${CONFIGURATION:-Debug}/Context Lens.app"
