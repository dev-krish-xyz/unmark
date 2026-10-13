#!/bin/sh
# Builds dist/Unmark-<version>.zip: universal, signed, and notarized when credentials exist.
#
# Environment:
#   VERSION              defaults to the latest git tag (without the leading "v")
#   CODESIGN_IDENTITY    "Developer ID Application: Name (TEAMID)"; ad-hoc signature when unset
#   NOTARY_PROFILE       notarytool keychain profile, or
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#   SOURCE_DATE_EPOCH    archive timestamps; defaults to the last commit time
set -eu
cd "$(dirname "$0")/.."

version="${VERSION:-$(git describe --tags --always --dirty | sed 's/^v//')}"
identity="${CODESIGN_IDENTITY:--}"
epoch="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
app="build/Unmark.app"
zip="dist/Unmark-$version.zip"

GIT_VERSION="$version" UNIVERSAL=1 CODESIGN_IDENTITY="$identity" Scripts/build-app.sh

archive() {
  # Fixed timestamps so identical inputs produce an identical archive.
  find "$app" -exec touch -h -t "$(date -r "$epoch" +%Y%m%d%H%M.%S)" {} +
  mkdir -p dist
  rm -f "$zip"
  ditto -c -k --norsrc --noextattr --keepParent "$app" "$zip"
}
archive

notarized=no
if [ -n "${NOTARY_PROFILE:-}${APPLE_ID:-}" ]; then
  if [ "$identity" = "-" ]; then
    echo "Notarization needs a Developer ID signature (set CODESIGN_IDENTITY)." >&2
    exit 1
  fi
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$zip" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" --wait
  fi
  xcrun stapler staple "$app"
  archive
  notarized=yes
fi

(cd dist && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
echo "Release: $zip"
echo "  signature:  $([ "$identity" = "-" ] && echo "ad-hoc (not Developer ID)" || echo "$identity")"
echo "  notarized:  $notarized"
echo "  sha256:     $(cut -d' ' -f1 "$zip.sha256")"
