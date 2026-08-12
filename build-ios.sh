#!/bin/bash
# Builds NatesNotes.app for the iOS Simulator and installs it.
#   ./build-ios.sh          build only
#   ./build-ios.sh run      build, install and launch
#
# SwiftPM can't emit an iOS app bundle, so this assembles one directly — the
# same thing build.sh does for macOS.
set -euo pipefail
cd "$(dirname "$0")"

DEVICE="${NN_SIMULATOR:-iPhone 17 Pro}"
TARGET="arm64-apple-ios18.0-simulator"
BUILD=".build/ios"
APP="$BUILD/NatesNotes.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

LAUNCH="no"
[ "${1:-}" = "run" ] && LAUNCH="yes"

rm -rf "$BUILD"
mkdir -p "$APP"

# SyncKit stays a real module so the shared sources import it exactly as they
# do on macOS.
echo "▸ Compiling SyncKit…"
xcrun -sdk iphonesimulator swiftc \
    -target "$TARGET" -sdk "$SDK" \
    -module-name SyncKit \
    -emit-module -emit-module-path "$BUILD/SyncKit.swiftmodule" \
    -emit-library -static -o "$BUILD/libSyncKit.a" \
    -O -wmo \
    Sources/SyncKit/*.swift

echo "▸ Compiling NatesNotes…"
xcrun -sdk iphonesimulator swiftc \
    -target "$TARGET" -sdk "$SDK" \
    -module-name NatesNotes \
    -I "$BUILD" -L "$BUILD" -lSyncKit \
    -O -wmo \
    -o "$APP/NatesNotes" \
    Sources/NatesNotes/Shared/*.swift iOS/*.swift

cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Nate's Notes</string>
    <key>CFBundleDisplayName</key>       <string>Nate's Notes</string>
    <key>CFBundleExecutable</key>        <string>NatesNotes</string>
    <key>CFBundleIdentifier</key>        <string>com.natesnotes.ios</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSRequiresIPhoneOS</key>        <true/>
    <key>MinimumOSVersion</key>          <string>18.0</string>
    <key>UILaunchScreen</key>            <dict/>
    <key>UIUserInterfaceStyle</key>      <string>Dark</string>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key><false/>
    </dict>
</dict>
PLIST
echo '</plist>' >> "$APP/Info.plist"

# The icon lives in an asset catalog so the Xcode project and this script use
# the same source. actool compiles it and reports the Info.plist keys that name
# it, which are merged in rather than hand-written.
echo "▸ Compiling the icon…"
xcrun actool iOS/Assets.xcassets \
    --compile "$APP" \
    --platform iphonesimulator \
    --minimum-deployment-target 18.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$BUILD/icon-partial.plist" \
    --output-format human-readable-text >/dev/null
/usr/libexec/PlistBuddy -c "Merge $BUILD/icon-partial.plist" "$APP/Info.plist" >/dev/null

echo "▸ Done: $APP"

if [ "$LAUNCH" = "yes" ]; then
    UDID="$(xcrun simctl list devices available \
            | grep -m1 "$DEVICE (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    if [ -z "$UDID" ]; then
        echo "No simulator named '$DEVICE'. Set NN_SIMULATOR to one of:"
        xcrun simctl list devices available | grep -E "iPhone|iPad" | sed 's/^/  /'
        exit 1
    fi
    xcrun simctl boot "$UDID" 2>/dev/null || true
    xcrun simctl install "$UDID" "$APP"
    xcrun simctl launch "$UDID" com.natesnotes.ios
    echo "▸ Launched on $DEVICE"
fi
