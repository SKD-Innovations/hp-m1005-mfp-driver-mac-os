#!/bin/sh
set -eu

app="build/M1005Printer.app"
setup="$app/Contents/MacOS/M1005 Setup"
service="$app/Contents/Resources/m1005-printer-service"
encoder="$app/Contents/Resources/m1005-xqx-encode"
agent="$app/Contents/Library/LaunchAgents/com.m1005printer.service.v6.plist"
test_directory=$(mktemp -d /private/tmp/m1005-phase5-test.XXXXXX)
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM

test -x "$setup"
test -x "$service"
test -x "$encoder"
test -f "$app/Contents/Resources/Source/foo2xqx/foo2xqx.c"
plutil -lint "$app/Contents/Info.plist" >/dev/null
plutil -lint "$agent" >/dev/null
test "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = \
    "com.m1005printer.setup"
test "$("$service" --version)" = "0.5.1"
test "$(file "$setup" "$service" "$encoder" | grep -c 'arm64')" -eq 3
dither_result=$("$service" --dither-self-test)
test "$(printf '%s\n' "$dither_result" | grep -c '^halftone=enabled$')" -eq 1
test "$(printf '%s\n' "$dither_result" | grep -c '^photo-levels=256$')" -eq 1
test "$(printf '%s\n' "$dither_result" | grep -c '^default-quality=high$')" -eq 1
grep -q 'print-quality-default=high' macos/M1005SetupApp.swift
grep -q 'cupsPrintQuality-default=High' macos/M1005SetupApp.swift

if otool -L "$service" | grep -Eq '/opt/homebrew|/usr/local'; then
    echo "Phase 5 service contains a package-manager runtime dependency." >&2
    exit 1
fi

codesign --verify --deep --strict "$app"
"$setup" --validate-bundle >/dev/null
M1005_XQX_TIMESTAMP=20260718172322 zsh -c \
    'exec -a Contents/Resources/m1005-printer-service "$1" --self-test "$2" "$3"' \
    phase5-test "$service" artifacts/m1005-a4-600.pbm \
    "$test_directory/relative-argv.xqx" >/dev/null
cmp tests/fixtures/known-good-m1005-a4-600.xqx \
    "$test_directory/relative-argv.xqx"

echo "Phase 5 app bundle, embedded service, and signature checks passed."
