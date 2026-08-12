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
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "  (ad-hoc signing skipped)"

echo "▸ Done: $(pwd)/$APP"

if [ "$LAUNCH" = "yes" ]; then
    open "$APP"
fi
