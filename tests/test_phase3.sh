#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /private/tmp/m1005-phase3-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

M1005_XQX_TIMESTAMP=20260718172322 \
    "$root/build/m1005-printer-app" --self-test \
    "$root/artifacts/m1005-a4-600.pbm" "$test_dir/output.xqx" \
    > "$test_dir/capabilities.txt"

cmp "$root/tests/fixtures/known-good-m1005-a4-600.xqx" \
    "$test_dir/output.xqx"
grep -q '^media=iso_a4_210x297mm$' "$test_dir/capabilities.txt"
grep -q '^resolution=600x600$' "$test_dir/capabilities.txt"
grep -q '^color=monochrome$' "$test_dir/capabilities.txt"
grep -q '^sides=one-sided$' "$test_dir/capabilities.txt"
grep -q '^raster=image/pwg-raster,image/urf$' "$test_dir/capabilities.txt"
grep -q '^usb=03f0:3b17$' "$test_dir/capabilities.txt"

file "$root/build/m1005-printer-app" | grep -q 'arm64'
test -s "$root/artifacts/m1005-a4-600.pwg"
test -s "$root/artifacts/m1005-a4-600.urf"
echo "Phase 3 bridge and capability tests passed."
