#!/usr/bin/env bash
# Build a signed, notarized release zip for the Homebrew cask and print its sha256.
#
#   scripts/release.sh [version]
#
# The version comes from MARKETING_VERSION in project.yml; a version argument must match it.
# Needs a "Developer ID Application" identity in the login keychain and an App Store Connect API
# key in ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (for notarytool). SIGN_IDENTITY=- skips
# signing and notarization, for testing the packaging only.
#
# To reuse for another app, change the block below. Every executable listed in EXTRA_BINARIES
# (paths inside the bundle) is signed before the app itself.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Context Lens"                         # PRODUCT_NAME, so the bundle is "$APP_NAME.app"
SCHEME="ContextLens"
BUNDLE_ID="com.prismalabs.contextlens"
ZIP_NAME="context-lens"                         # release asset: $ZIP_NAME-$VERSION.zip
EXTRA_BINARIES=("Contents/MacOS/context-lens")  # nested executables, signed first
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

version=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)
[ -n "$version" ] || { echo "no MARKETING_VERSION in project.yml" >&2; exit 1; }
if [ $# -gt 0 ] && [ "$1" != "$version" ]; then
  echo "project.yml says $version, not $1; update MARKETING_VERSION first" >&2
  exit 1
fi

xcode-disk-guard preflight --protect "$PWD" >/dev/null
out="$PWD/build/release"
rm -rf "$out"
mkdir -p "$out"
xcodegen generate --quiet
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build -quiet
ditto "build/DerivedData/Build/Products/Release/$APP_NAME.app" "$out/$APP_NAME.app"
app="$out/$APP_NAME.app"

actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[ "$actual_id" = "$BUNDLE_ID" ] || { echo "bundle id is $actual_id, expected $BUNDLE_ID" >&2; exit 1; }

# Sign inside out with the hardened runtime and a secure timestamp, as notarization requires.
sign=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" = "-" ] && sign=(codesign --force --sign -)
for bin in "${EXTRA_BINARIES[@]}"; do "${sign[@]}" "$app/$bin"; done
"${sign[@]}" "$app"
codesign --verify --strict --deep "$app"

zip="$out/$ZIP_NAME-$version.zip"
if [ "$SIGN_IDENTITY" != "-" ]; then
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  xcrun notarytool submit "$out/notarize.zip" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" --wait --timeout 30m --output-format json | tee "$out/notarize.json"
  grep -q '"status" *: *"Accepted"' "$out/notarize.json" || {
    echo "notarization failed; run: xcrun notarytool log <id> --key ... to see why" >&2
    exit 1
  }
  rm "$out/notarize.zip"
  xcrun stapler staple "$app"
  spctl --assess --type execute -vv "$app"
fi
ditto -c -k --keepParent "$app" "$zip"
echo "version $version"
echo "zip     $zip"
echo "sha256  $(shasum -a 256 "$zip" | cut -d' ' -f1)"
