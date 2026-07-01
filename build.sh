#!/bin/bash
# Build m_capture.app (native Swift) and a DMG.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/m_capture.app"
VERSION="1.0.1"

# `./build.sh --run` quits any running instance, relaunches from build/, and
# skips the DMG — the fast dev loop. Plain `./build.sh` builds the DMG too.
RUN=0
for arg in "$@"; do [ "$arg" = "--run" ] && RUN=1; done

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling Swift sources"
# Pin the deployment target to match LSMinimumSystemVersion below; ScreenCaptureKit's
# SCScreenshotManager (the capture path) needs macOS 14. Without an explicit -target,
# swiftc bakes in the build host's OS as the minimum and the app refuses to launch on
# 14. (swiftc ignores MACOSX_DEPLOYMENT_TARGET, so this must be -target.)
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" \
    -o "$APP/Contents/MacOS/m_capture" \
    "$DIR"/Sources/*.swift \
    -framework AppKit -framework Carbon -framework ScreenCaptureKit

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>m_capture</string>
    <key>CFBundleIdentifier</key><string>io.mesoneer.mcapture</string>
    <key>CFBundleName</key><string>m_capture</string>
    <key>CFBundleDisplayName</key><string>m_capture</string>
    <key>CFBundleIconFile</key><string>m_capture</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>m_capture captures your screen to take screenshots.</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 mesoneer AG. MIT License.</string>
</dict>
</plist>
PLIST

echo "==> Generating app icon"
# makeicon.swift writes the multi-resolution .icns directly (no sips/iconutil,
# which would otherwise need a system temp dir).
swift "$DIR/tools/makeicon.swift" "$APP/Contents/Resources/m_capture.icns"

echo "==> Code signing"
# Sign with a stable self-signed identity if one exists, so macOS keeps the
# Screen Recording grant across rebuilds (ad-hoc signatures change every build,
# which is why the permission keeps resetting). See README "Faster dev loop".
SIGN_ID="-"
# Match without -v: a self-signed cert is a usable code-signing identity even
# when it isn't "valid" (i.e. not trusted as a root). codesign signs fine with
# it, and the stable Authority is what makes the Screen Recording grant persist.
if security find-identity -p codesigning 2>/dev/null | grep -q "m_capture-dev"; then
    SIGN_ID="m_capture-dev"
    echo "    stable identity 'm_capture-dev' — Screen Recording grant persists"
else
    echo "    ad-hoc (create a 'm_capture-dev' code-signing cert to stop re-granting)"
fi
codesign --force --deep -s "$SIGN_ID" "$APP"

if [ "$RUN" = "1" ]; then
    echo "==> Relaunching"
    killall m_capture 2>/dev/null || true
    open "$APP"
    echo "==> Done: $APP (relaunched, DMG skipped)"
    exit 0
fi

echo "==> Building DMG"
DMG="$DIR/m_capture.dmg"
# Stage inside build/ rather than the system temp dir, so a sandboxed build can
# write here (see the makeicon note above).
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/m_capture.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "m_capture" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $APP"
echo "==> DMG:  $DMG"
