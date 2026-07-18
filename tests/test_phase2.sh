#!/bin/sh
set -eu

project_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
test_dir="$project_dir/build/phase2-tests"
encoder="$project_dir/build/m1005-xqx-encode"
decoder="$project_dir/build/m1005-xqx-decode"
generator="$project_dir/build/generate-test-pbm"
known_good="$project_dir/tests/fixtures/known-good-m1005-a4-600.xqx"

mkdir -p "$test_dir"

baseline_pbm="$test_dir/m1005-a4-600.pbm"
actual_xqx="$test_dir/m1005-a4-600.xqx"
decoded="$test_dir/m1005-a4-600.decode.txt"

"$generator" "$baseline_pbm"

M1005_XQX_TIMESTAMP=20260718172322 \
    "$encoder" -r600x600 -g4960x7016 -p9 -m1 -n1 -d1 -s7 \
    -u88x84 -l88x84 -L3 -T3 -J "M1005 Phase 1" -U "Codex" \
    < "$baseline_pbm" > "$actual_xqx"

cmp "$known_good" "$actual_xqx"
"$decoder" "$actual_xqx" > "$decoded"

grep -Fq 'XQX_MAGIC' "$decoded"
grep -Fq 'XQXI_COPIES, 1' "$decoded"
grep -Fq 'XQXI_RESOLUTION_X, 600' "$decoded"
grep -Fq 'XQXI_RESOLUTION_Y, 600' "$decoded"
grep -Fq 'XQXI_RASTER_X, 4864' "$decoded"
grep -Fq 'XQXI_RASTER_Y, 6848' "$decoded"
grep -Fq 'XQXI_VIDEO_BPP, 1' "$decoded"
grep -Fq 'XQXI_VIDEO_X, 4784' "$decoded"
grep -Fq 'XQXI_DMPAPER, 9' "$decoded"
grep -Fq 'XQX_END_DOC' "$decoded"
grep -Fq 'Total size: 2034 bytes' "$decoded"
test "$(grep -c 'XQX_START_PAGE' "$decoded")" -eq 1

multi_pbm="$test_dir/m1005-a4-600-2page.pbm"
multi_xqx="$test_dir/m1005-a4-600-2page.xqx"
multi_decoded="$test_dir/m1005-a4-600-2page.decode.txt"
"$generator" "$multi_pbm" 2
M1005_XQX_TIMESTAMP=20260718172322 \
    "$encoder" -r600x600 -g4960x7016 -p9 -m1 -n1 -d1 -s7 \
    -u88x84 -l88x84 -L3 -T3 < "$multi_pbm" > "$multi_xqx"
"$decoder" "$multi_xqx" > "$multi_decoded"
test "$(grep -c 'XQX_START_PAGE' "$multi_decoded")" -eq 2

copies_xqx="$test_dir/m1005-a4-600-2copies.xqx"
copies_decoded="$test_dir/m1005-a4-600-2copies.decode.txt"
M1005_XQX_TIMESTAMP=20260718172322 \
    "$encoder" -r600x600 -g4960x7016 -p9 -m1 -n2 -d1 -s7 \
    -u88x84 -l88x84 -L3 -T3 < "$baseline_pbm" > "$copies_xqx"
"$decoder" "$copies_xqx" > "$copies_decoded"
grep -Fq 'XQXI_COPIES, 2' "$copies_decoded"

if M1005_XQX_TIMESTAMP=20260718172322 \
    "$encoder" -r300x300 -g2480x3508 -p9 \
    < "$baseline_pbm" > "$test_dir/invalid-resolution.xqx" \
    2> "$test_dir/invalid-resolution.log"; then
    echo "300x300 was unexpectedly accepted" >&2
    exit 1
fi
grep -Fq 'Unsupported resolution 300x300' "$test_dir/invalid-resolution.log"

if M1005_XQX_TIMESTAMP=invalid \
    "$encoder" -r600x600 -g4960x7016 -p9 \
    < "$baseline_pbm" > "$test_dir/invalid-timestamp.xqx" \
    2> "$test_dir/invalid-timestamp.log"; then
    echo "invalid deterministic timestamp was unexpectedly accepted" >&2
    exit 1
fi
grep -Fq 'must contain exactly 14 digits' "$test_dir/invalid-timestamp.log"

file "$encoder" | grep -Fq 'arm64'
file "$decoder" | grep -Fq 'arm64'
if otool -L "$encoder" | grep -Fq 'libjbig'; then
    echo "encoder unexpectedly depends on a system JBIG library" >&2
    exit 1
fi

echo "Phase 2 regression tests passed"
