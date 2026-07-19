#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$TMP/target" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
cat > "$BIN/llvm-profdata" <<'EOF'
#!/bin/bash
out=""
while test $# -gt 0; do
  if test "$1" = "-o"; then out="$2"; shift 2; else shift; fi
done
printf merged > "$out"
EOF
cat > "$BIN/llvm-cov" <<'EOF'
#!/bin/bash
if test "$1" = export; then
  printf 'SF:/src/crash.c\nDA:1,1\nend_of_record\n'
fi
EOF
chmod +x "$TMP/target" "$BIN/llvm-profdata" "$BIN/llvm-cov"
P="$BIN:/usr/bin:/bin"
export CC=/bin/true

FLAT="$TMP/flat"
mkdir -p "$FLAT"
printf crash > "$FLAT/crash-only"
if PATH="$P" bash ./cov-analysis search /src/crash.c:1 -d "$FLAT" -e "$TMP/target @@" -q >"$TMP/flat.no" 2>&1; then
  die "flat crash-only search without --crashes should fail"
fi
out=$(PATH="$P" bash ./cov-analysis search /src/crash.c:1 -d "$FLAT" \
  -e "$TMP/target @@" --crashes 2>"$TMP/flat.err") || die "flat crash-only --crashes failed"
assert_eq "$out" "$FLAT/crash-only" "flat crash-only match"
grep -q 'Inputs to scan  : 1 (queue=0, crashes/timeouts=1)' "$TMP/flat.err" \
  || die "flat selected-input count is wrong"

AFL="$TMP/afl"
mkdir -p "$AFL/crashes"
printf crash > "$AFL/crashes/id:000000,sig:11"
if PATH="$P" bash ./cov-analysis search /src/crash.c:1 -d "$AFL" -e "$TMP/target @@" -q >"$TMP/afl.no" 2>&1; then
  die "AFL crash-only search without --crashes should fail"
fi
out=$(PATH="$P" bash ./cov-analysis search /src/crash.c:1 -d "$AFL" \
  -e "$TMP/target @@" --crashes -q 2>/dev/null) || die "AFL crash-only --crashes failed"
assert_eq "$out" "$AFL/crashes/id:000000,sig:11" "AFL crash-only match"

echo "[PASS] test_search_crash_only"
