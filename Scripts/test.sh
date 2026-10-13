#!/bin/sh
# Runs the test suite. With Command Line Tools only (no Xcode), SwiftPM does not pass the
# swift-testing macro plugin to every compile job, so point the compiler at it explicitly.
set -eu
cd "$(dirname "$0")/.."
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ] && ! xcode-select -p | grep -q '\.app/'; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
