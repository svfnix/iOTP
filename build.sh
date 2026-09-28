#!/bin/bash
# Builds iOTP.app into ./dist and ad-hoc signs it.
#   ./build.sh            build only
#   ./build.sh --install  also copy to /Applications and launch
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP_NAME="iOTP"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# The Command Line Tools toolchain lacks the SwiftUI macro plugins, so prefer a full Xcode when present.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "==> Compiling (release)"
swift build -c release

BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -f "$BINARY" ] || { echo "Build produced no binary at $BINARY"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Rendering icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
if swift "$ROOT/tools/MakeIcon.swift" "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "    icon ok"
else
    echo "    icon generation skipped (app still works, just without a custom icon)"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    echo "Done — look for the key icon in the menu bar."
else
    echo "Done: $APP"
    echo "Run it with:  open \"$APP\"     (or ./build.sh --install)"
fi
