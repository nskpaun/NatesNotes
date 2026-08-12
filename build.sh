#!/bin/bash
# Builds NatesNotes.app — a normal double-clickable macOS bundle.
#   ./build.sh          release build
#   ./build.sh debug    debug build
#   ./build.sh run      build, then launch
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
LAUNCH="no"
for arg in "$@"; do
    case "$arg" in
        debug)   CONFIG="debug" ;;
        release) CONFIG="release" ;;
        run)     LAUNCH="yes" ;;
    esac
done

APP="NatesNotes.app"
CONTENTS="$APP/Contents"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/NatesNotes"

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/NatesNotes"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Nate's Notes</string>
    <key>CFBundleDisplayName</key>       <string>Nate's Notes</string>
    <key>CFBundleExecutable</key>        <string>NatesNotes</string>
    <key>CFBundleIdentifier</key>        <string>com.natesnotes.app</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# Ad-hoc signature so macOS treats it as a stable, launchable app.
# Sign with a stable identity when one is available.
#
# An ad-hoc signature is derived from the binary, so every rebuild produces a
# *different* one. The Keychain binds an item's access control to the signature
# of the app that created it, so with ad-hoc signing macOS sees a brand-new
# application after each build and asks for permission to read the sync token
# again — repeatedly, since a sync makes many authenticated requests. A real
# identity keeps that requirement stable, so "Always Allow" sticks.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 "Apple Development" \
        | sed -n 's/.*"\(.*\)"/\1/p')
fi

if [ -n "$IDENTITY" ]; then
    echo "▸ Signing as: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null \
        || codesign --force --deep --sign - "$APP" 2>/dev/null
else
    echo "  (no signing identity found — using ad-hoc; expect Keychain prompts)"
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "▸ Done: $(pwd)/$APP"

if [ "$LAUNCH" = "yes" ]; then
    open "$APP"
fi
