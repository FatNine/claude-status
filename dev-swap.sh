#!/bin/bash
# Build Release, install to /Applications, sign with the stable local dev cert
# (so the Accessibility/TCC grant persists across rebuilds), and relaunch.
set -e
cd "$(dirname "$0")"
CERT="Claude Status Local Dev"
xcodebuild -project "Claude Status.xcodeproj" -scheme "Claude Status" -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED" | grep -vi CoreSimulator
osascript -e 'tell application "Claude Status" to quit' 2>/dev/null || true
pkill -f "Claude Status.app/Contents/MacOS" 2>/dev/null || true
sleep 1
rm -rf "/Applications/Claude Status.app"
cp -R "build/Build/Products/Release/Claude Status.app" /Applications/
xattr -dr com.apple.quarantine "/Applications/Claude Status.app"
codesign --force --deep --sign "$CERT" "/Applications/Claude Status.app"
open "/Applications/Claude Status.app"
echo "✓ swapped + signed ($CERT)"
