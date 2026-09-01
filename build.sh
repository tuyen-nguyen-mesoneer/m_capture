#!/bin/bash
# Build m_capture.app (native Swift) and a DMG.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/m_capture.app"
VERSION="1.8.0"

# `./build.sh --run` quits any running instance, relaunches from build/, and
# skips the DMG — the fast dev loop. Plain `./build.sh` builds the DMG too.
# Add `--simulate` to relaunch in simulate-recording mode (no capture, no file) — the way
# to exercise the recording UI while the Screen Recording grant is still pending. It has
# to be passed here rather than via `open --args`: the relaunch below replaces argv, and
# `open --args` on an already-running menu-bar app is dropped entirely.
#
# Simulate mode is ALSO a persisted app preference (Settings -> Video), and the permission
# alert's "Simulate Instead" button sets it. So a plain `--run` inherits whatever was last
# saved: it does not mean "record for real". The relaunch below reports the effective state
# every time, and `--no-simulate` clears the saved flag.
RUN=0
SIMULATE=0
NO_SIMULATE=0
for arg in "$@"; do
    [ "$arg" = "--run" ] && RUN=1
    [ "$arg" = "--simulate" ] && SIMULATE=1
    [ "$arg" = "--no-simulate" ] && NO_SIMULATE=1
done
if [ "$SIMULATE" = "1" ] && [ "$NO_SIMULATE" = "1" ]; then
    echo "!!! --simulate and --no-simulate are contradictory. Aborting." >&2
    exit 1
fi
if [ "$SIMULATE" = "1" ] && [ "$RUN" != "1" ]; then
    echo "!!! --simulate only applies with --run (it is a relaunch flag). Aborting." >&2
    exit 1
fi
if [ "$NO_SIMULATE" = "1" ] && [ "$RUN" != "1" ]; then
    echo "!!! --no-simulate only applies with --run (it is a relaunch flag). Aborting." >&2
    exit 1
fi

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

echo "==> Bundling brand fonts"
# Open Sans is the mesoneer corporate typeface (Theme.font). ATSApplicationFontsPath
# registers everything in this folder at launch; Theme also registers it explicitly so
# tools/shots.swift, which draws with Theme outside the bundle, gets the same faces.
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$DIR/Resources/Fonts/OpenSans-Variable.ttf" "$APP/Contents/Resources/Fonts/"
cp "$DIR/Resources/Fonts/OFL.txt" "$APP/Contents/Resources/Fonts/"

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
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>NSScreenCaptureUsageDescription</key><string>m_capture captures your screen to take screenshots.</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 mesoneer AG. MIT License.</string>${AUTO_INSTALL_PLIST}
</dict>
</plist>
PLIST

echo "==> Generating app icon"
# makeicon writes the multi-resolution .icns directly (no sips/iconutil, which would
# otherwise need a system temp dir). It is *compiled against the app's own* Logo.swift +
# Theme.swift rather than run as a standalone script, so the icon is the same official
# brand vector the menu and About card draw — one definition, no copy of the logo to go
# stale. swiftc puts top-level code only in a file called main.swift, hence the copy.
ICONGEN="$BUILD/icongen"
mkdir -p "$ICONGEN"
cp "$DIR/tools/makeicon.swift" "$ICONGEN/main.swift"
swiftc -swift-version 5 -O -o "$ICONGEN/makeicon" \
    "$ICONGEN/main.swift" "$DIR/Sources/Logo.swift" "$DIR/Sources/Theme.swift" \
    -framework AppKit
"$ICONGEN/makeicon" "$APP/Contents/Resources/m_capture.icns"
rm -rf "$ICONGEN"

echo "==> Code signing"
# A *stable* signing identity is what lets macOS keep the Screen Recording grant across
# updates — the grant is keyed to the identity's certificate (its SHA-1), NOT the app's
# name or path. Ad-hoc signatures ("-") change every build, which is why the permission
# resets. There is exactly ONE identity, m_capture-release: CI signs every published
# release with it, and contributors import the same cert locally (certs/m_capture-release.p12,
# via tools/import-cert.sh) so dev rebuilds keep the grant AND share it with the shipped
# app. Note a self-signed cert's identity is its HASH, not its name — rolling your own
# cert called "m_capture-release" is a DIFFERENT identity and won't match.
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
    # Dev rebuild — the shared identity (if imported locally), so the Screen Recording
    # grant survives rebuilds and matches the shipped app too; else ad-hoc.
    if [ -n "$(find_identity 'm_capture-release')" ]; then
        SIGN_ID="m_capture-release"
        echo "    shared identity 'm_capture-release' — your local Screen Recording grant persists"
    else
        echo "    ad-hoc (run ./tools/import-cert.sh to stop re-granting on every rebuild)"
    fi
else
    # Release build (DMG) — require the shared release identity so users keep their grant.
    RELEASE_SHA="$(find_identity 'm_capture-release')"
    if [ -n "$RELEASE_SHA" ]; then
        SIGN_ID="m_capture-release"
        echo "    release identity 'm_capture-release' ($RELEASE_SHA)"
    else
        echo "    WARNING: no 'm_capture-release' identity — this build will NOT preserve users'" >&2
        echo "             Screen Recording grant across updates (run ./tools/import-cert.sh)." >&2
        echo "             falling back to ad-hoc — OK for local DMG testing, NOT for release." >&2
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
    # Wait for it to actually exit before opening the new one: AppDelegate's
    # terminateIfAlreadyRunning() makes the *new* instance quit itself while the old one is
    # still alive, which silently drops --args (and leaves the old build running).
    for _ in $(seq 1 25); do pgrep -x m_capture >/dev/null 2>&1 || break; sleep 0.2; done
    # Report the mode the app will actually come up in. Simulate is a saved preference, so
    # "I did not pass --simulate" is NOT the same as "this build records for real" — say so
    # loudly rather than let a stale flag look like a broken recorder.
    BUNDLE_ID="io.mesoneer.mcapture"
    if [ "$NO_SIMULATE" = "1" ]; then
        defaults write "$BUNDLE_ID" simulateRecording -bool false 2>/dev/null || true
        echo "    simulate recording: OFF (saved setting cleared)"
    fi
    if [ "$SIMULATE" = "1" ]; then
        echo "    simulate recording: ON for this launch — nothing is captured or saved"
        open "$APP" --args --simulate-recording
    else
        if [ "$(defaults read "$BUNDLE_ID" simulateRecording 2>/dev/null)" = "1" ]; then
            echo "    !!! simulate recording: ON (saved setting) — recordings will capture NOTHING." >&2
            echo "        Clear it with ./build.sh --run --no-simulate, or Settings > Video." >&2
        else
            echo "    simulate recording: off — recordings capture for real"
        fi
        open "$APP"
    fi
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
