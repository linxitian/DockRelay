#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="$PWD/build/DockRelay.app"
mkdir -p "$app/Contents/MacOS"
/usr/bin/xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
    -fobjc-arc -Os -Wall -Wextra -Werror \
    -framework AppKit -framework ApplicationServices -framework ServiceManagement \
    Sources/main.m Sources/DockState.m Sources/Relay.m -o "$app/Contents/MacOS/DockRelay"
/bin/cp Info.plist "$app/Contents/Info.plist"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
    /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --strict "$app"
printf '%s\n' "$app"
