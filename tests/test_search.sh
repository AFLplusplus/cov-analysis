#!/usr/bin/env bash
# Tests for the `search` subcommand: pure helpers (always) + an integration
# test gated on clang/llvm-cov (skipped cleanly when the toolchain is absent).
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)

# ── parse_target_spec ────────────────────────────────────────────────────────
out=$(parse_target_spec "src/foo.c:123")
assert_eq "$out" "$(printf 'src/foo.c\t123')" "parse simple spec"

# Path containing colons: split on the LAST colon only.
out=$(parse_target_spec "a:b/foo.c:99")
assert_eq "$out" "$(printf 'a:b/foo.c\t99')" "parse colon-in-path spec"

# Invalid specs must return non-zero (capture rc without tripping set -e).
rc=0; parse_target_spec "no-colon"      >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1" "reject missing colon"
rc=0; parse_target_spec "src/foo.c:abc" >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1" "reject non-numeric line"
rc=0; parse_target_spec "src/foo.c:0"   >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1" "reject zero line"
rc=0; parse_target_spec ":123"          >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1" "reject empty file"

echo "[PASS] parse_target_spec"

# ── lcov_line_state ──────────────────────────────────────────────────────────
# Synthetic LCOV: src/foo.c has line 10 covered (count 5), line 11 executed-zero
# (count 0); line 12 has no DA record. other.c is a non-matching file.
LCOV=$(cat <<'EOF'
SF:/build/src/foo.c
DA:10,5
DA:11,0
end_of_record
SF:/build/other.c
DA:10,7
end_of_record
EOF
)

assert_eq "$(printf '%s\n' "$LCOV" | lcov_line_state src/foo.c 10)" "covered"   "lcov covered (count>0)"
assert_eq "$(printf '%s\n' "$LCOV" | lcov_line_state src/foo.c 11)" "uncovered" "lcov uncovered (count==0)"
assert_eq "$(printf '%s\n' "$LCOV" | lcov_line_state src/foo.c 12)" "absent"    "lcov absent (no DA record)"
# Suffix match must respect a path boundary: 'oo.c' must NOT match '/build/src/foo.c'.
assert_eq "$(printf '%s\n' "$LCOV" | lcov_line_state oo.c 10)"      "absent"    "lcov suffix boundary"
# Exact absolute path match.
assert_eq "$(printf '%s\n' "$LCOV" | lcov_line_state /build/src/foo.c 10)" "covered" "lcov exact path"
# Line 10 in other.c is covered too (separate SF block).
assert_eq "$(printf '%s\n' "$LCOV" | lcov_line_state other.c 10)"  "covered"   "lcov second SF block"

echo "[PASS] lcov_line_state"

# ── integration (gated on clang + llvm-cov) ──────────────────────────────────
# detect_clang is provided by tests/lib.sh.
CLANG="$(detect_clang || true)"
if test -z "$CLANG" || ! find_tool llvm-cov >/dev/null 2>&1 || ! find_tool llvm-profdata >/dev/null 2>&1; then
  echo "[SKIP] search integration test (clang/llvm-cov/llvm-profdata not found)"
  echo "[PASS] test_search (unit only)"
  exit 0
fi

# Build the coverage binary: driver (tests/cov.c) + harness (tests/search_harness.c).
COVBIN="$TMP/searchcov"
"$CLANG" -fprofile-instr-generate -fcoverage-mapping \
  -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1 \
  tests/cov.c tests/search_harness.c -o "$COVBIN" 2>"$TMP/build.log" || {
    cat "$TMP/build.log" >&2
    die "failed to build coverage harness"
  }

# Resolve the marked line numbers from the harness source. Paths are relative to
# the repo root (the test cd'd there above), so the SF path llvm-cov records ends
# with "tests/search_harness.c" and the lcov_line_state suffix match succeeds.
LINE_A=$(grep -n 'SEARCH_LINE_A' tests/search_harness.c | head -1 | cut -d: -f1)
LINE_B=$(grep -n 'SEARCH_LINE_B' tests/search_harness.c | head -1 | cut -d: -f1)
LINE_Z=$(grep -n 'SEARCH_LINE_Z' tests/search_harness.c | head -1 | cut -d: -f1)
HARNESS="tests/search_harness.c"

# AFL fixture: input 1 starts with 'A', input 2 starts with 'B'.
AFL_DIR="$TMP/afl"; mkdir -p "$AFL_DIR/queue"
printf 'Ahello' > "$AFL_DIR/queue/id:000000,time:0,src:000"
printf 'Bworld' > "$AFL_DIR/queue/id:000001,time:0,src:000"

# search for LINE_A must return ONLY the 'A' input.
out_a=$(bash ./cov-analysis search "$HARNESS:$LINE_A" -d "$AFL_DIR" -e "$COVBIN @@" -q 2>/dev/null)
assert_eq "$(printf '%s\n' "$out_a" | grep -c 'id:000000')" "1" "LINE_A matches the A input"
assert_eq "$(printf '%s\n' "$out_a" | grep -c 'id:000001')" "0" "LINE_A excludes the B input"

# search for LINE_B must return ONLY the 'B' input.
out_b=$(bash ./cov-analysis search "$HARNESS:$LINE_B" -d "$AFL_DIR" -e "$COVBIN @@" -q 2>/dev/null)
assert_eq "$(printf '%s\n' "$out_b" | grep -c 'id:000001')" "1" "LINE_B matches the B input"
assert_eq "$(printf '%s\n' "$out_b" | grep -c 'id:000000')" "0" "LINE_B excludes the A input"

# search for LINE_Z (executable, never reached) returns nothing (union short-circuit).
out_z=$(bash ./cov-analysis search "$HARNESS:$LINE_Z" -d "$AFL_DIR" -e "$COVBIN @@" -q 2>/dev/null)
assert_eq "$(printf '%s' "$out_z" | grep -c .)" "0" "LINE_Z (unreached) returns no matches"

# Parallel scan must give the same result as serial.
out_a8=$(bash ./cov-analysis search "$HARNESS:$LINE_A" -d "$AFL_DIR" -e "$COVBIN @@" -t 4 -q 2>/dev/null)
assert_eq "$out_a8" "$out_a" "parallel scan matches serial"

echo "[PASS] search integration"
echo "[PASS] test_search"
