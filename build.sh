#!/bin/bash
# Build m_capture.app (native Swift) and a DMG.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/m_capture.app"
VERSION="1.2.2"

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

# Distributed (DMG) builds self-install into ~/Applications on first launch (see
# Relocator.swift); the dev --run fast loop must not move out of build/, so flag only
# non-run builds.
AUTO_INSTALL_PLIST=""
if [ "$RUN" != "1" ]; then
    AUTO_INSTALL_PLIST=$'\n    <key>MCAutoInstall</key><true/>'
fi

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
    <key>NSHumanReadableCopyright</key><string>© 2026 mesoneer AG. MIT License.</string>${AUTO_INSTALL_PLIST}
</dict>
</plist>
PLIST

echo "==> Generating app icon"
# makeicon.swift writes the multi-resolution .icns directly (no sips/iconutil,
# which would otherwise need a system temp dir).
swift "$DIR/tools/makeicon.swift" "$APP/Contents/Resources/m_capture.icns"

echo "==> Code signing"
# A *stable* signing identity is what lets macOS keep the Screen Recording grant across
# updates — the grant is keyed to the identity's certificate (its SHA-1), NOT the app's
# name or path. Ad-hoc signatures ("-") change every build, which is why the permission
# resets. Two deliberately separate roles — and note a self-signed cert's identity is its
# HASH, not its name, so two certs both named "m_capture-dev" are DIFFERENT identities:
#   • m_capture-dev      optional, per-developer, local — keeps YOUR rebuilds' grant.
#   • m_capture-release  the ONE shared identity every published release must use, so end
#                        users keep their grant across updates. Export it as a .p12 and
#                        import it on each release machine / CI. See CONTRIBUTING > Releasing.
# Set RELEASE_CERT_SHA to that shared cert's SHA-1 to hard-fail a release signed by the
# wrong identity (find it with: security find-identity -p codesigning).
RELEASE_CERT_SHA="649539CA96FD80DF1FD4C01E5F16F81B12427C00"

# Echo a code-signing identity's SHA-1 by (sub)name, or nothing. Matched without -v: a
# self-signed cert is usable for signing even when it isn't a trusted root (-v hides it).
find_identity() {
    security find-identity -p codesigning 2>/dev/null \
        | awk -v name="$1" '$0 ~ name { print $2; exit }' || true
}

SIGN_ID="-"
if [ "$RUN" = "1" ]; then
    # Dev rebuild — prefer the local convenience cert, else ad-hoc.
    if [ -n "$(find_identity 'm_capture-dev')" ]; then
        SIGN_ID="m_capture-dev"
        echo "    dev identity 'm_capture-dev' — your local Screen Recording grant persists"
    else
        echo "    ad-hoc (create an 'm_capture-dev' cert to stop re-granting on rebuild)"
    fi
else
    # Release build (DMG) — require the shared release identity so users keep their grant.
    RELEASE_SHA="$(find_identity 'm_capture-release')"
    if [ -n "$RELEASE_SHA" ]; then
        SIGN_ID="m_capture-release"
        echo "    release identity 'm_capture-release' ($RELEASE_SHA)"
    else
        echo "    WARNING: no 'm_capture-release' identity — this build will NOT preserve users'" >&2
        echo "             Screen Recording grant across updates (see CONTRIBUTING > Releasing)." >&2
        if [ -n "$(find_identity 'm_capture-dev')" ]; then
            SIGN_ID="m_capture-dev"
            echo "             falling back to 'm_capture-dev' — OK for local DMG testing, NOT for release." >&2
        else
            echo "             falling back to ad-hoc — OK for local DMG testing, NOT for release." >&2
        fi
    fi
    # If a canonical release identity is pinned, the chosen signer MUST match it.
    if [ -n "$RELEASE_CERT_SHA" ]; then
        CHOSEN_SHA=""
        [ "$SIGN_ID" != "-" ] && CHOSEN_SHA="$(find_identity "$SIGN_ID")"
        if [ "$CHOSEN_SHA" != "$RELEASE_CERT_SHA" ]; then
            echo "!!! Release signed by the WRONG identity (${CHOSEN_SHA:-ad-hoc}); expected $RELEASE_CERT_SHA." >&2
            echo "    Shipping this would reset every user's Screen Recording grant. Aborting." >&2
            exit 1
        fi
    fi
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
# No /Applications symlink: the app self-installs into ~/Applications on first launch
# (see Relocator.swift), so there's no drag target to mis-drop into the system folder.
rm -f "$DMG"
hdiutil create -volname "m_capture" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $APP"
echo "==> DMG:  $DMG"
