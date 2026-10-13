#!/bin/sh
# Builds build/Unmark.app from the Swift package.
#
#   Scripts/build-app.sh                 release build for this Mac's architecture, ad-hoc signed
#   UNIVERSAL=1 Scripts/build-app.sh     arm64 + x86_64
#   CODESIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh
set -eu
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
identity="${CODESIGN_IDENTITY:--}"
app="build/Unmark.app"

if [ "${UNIVERSAL:-0}" = 1 ]; then
  set -- --arch arm64 --arch x86_64
else
  set --
fi

swift build -c "$configuration" "$@"
binary="$(swift build -c "$configuration" "$@" --show-bin-path)/Unmark"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Unmark"
cp Resources/Info.plist "$app/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$app/Contents/PkgInfo"

if [ -n "${GIT_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$GIT_VERSION" "$app/Contents/Info.plist"
fi

strip -rSTx "$app/Contents/MacOS/Unmark" 2>/dev/null || true

if [ "$identity" = "-" ]; then
  codesign --force --options runtime --entitlements Resources/Unmark.entitlements --sign - "$app"
else
  codesign --force --options runtime --timestamp --entitlements Resources/Unmark.entitlements --sign "$identity" "$app"
fi
codesign --verify --strict "$app"
echo "Built $app ($(lipo -archs "$app/Contents/MacOS/Unmark"), signed: $identity)"
