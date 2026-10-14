#!/bin/bash
# Builds Whittle, installs it to /Applications and signs it there.
#
# Signing: macOS ties the microphone, Accessibility and Screen Recording permissions to the app's signature.
# A stable certificate keeps them across rebuilds; ad-hoc signing works but macOS asks again after every rebuild.
# The certificate is, in order:
#   1. WHITTLE_SIGN_IDENTITY (environment, or scripts/local.env, which git ignores)
#   2. the first "Apple Development" certificate in your keychain (free with any Apple ID: Xcode → Settings →
#      Accounts → add your Apple ID → Manage Certificates → + Apple Development)
#   3. ad hoc ("-")
# The signing happens in /Applications because iCloud Drive (if Documents is synced) keeps adding
# Finder metadata to the build folder, which codesign refuses.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f scripts/local.env ] && source scripts/local.env
command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen"; exit 1; }

IDENTITY="${WHITTLE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "No Apple Development certificate found: signing ad hoc. macOS will ask for permissions again after each rebuild."
fi

# Built outside Documents, so iCloud doesn't sync it and macOS doesn't list it as another copy of the app.
BUILD_DIR="$HOME/Library/Caches/Whittle-build/Release"
BUILT="$BUILD_DIR/Build/Products/Release/Whittle.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TARGET="${WHITTLE_INSTALL_PATH:-/Applications/Whittle.app}"

echo "Building…"
xcodegen generate >/dev/null
xcodebuild -project Scriber.xcodeproj -scheme Scriber -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[ -d "$BUILT" ] || { echo "Build failed."; exit 1; }
"$LSREGISTER" -u "$BUILT" 2>/dev/null || true

if [ "$TARGET" = "/Applications/Whittle.app" ] && pgrep -x Whittle >/dev/null; then
  echo "Quitting the running Whittle…"
  osascript -e 'tell application "Whittle" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Whittle 2>/dev/null || true
fi

echo "Installing to ${TARGET}…"
rm -rf "$TARGET"
ditto --norsrc --noextattr --noacl "$BUILT" "$TARGET"

echo "Signing…"
xattr -cr "$TARGET"
codesign --force --sign "$IDENTITY" --timestamp=none "$TARGET"
codesign --verify --strict "$TARGET"

if [ "$TARGET" = "/Applications/Whittle.app" ]; then
  # Tell Finder and System Settings to pick up the new icon rather than a cached one.
  touch "$TARGET"
  "$LSREGISTER" -f "$TARGET" || true
  open "$TARGET"
  echo "Done. Whittle is running from ${TARGET}."
else
  echo "Done. Signed copy at ${TARGET}."
fi
