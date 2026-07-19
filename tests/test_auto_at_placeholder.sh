#!/usr/bin/env bash
# Feature test: when the coverage binary is built from the cov-analysis driver
# (it reads inputs from file arguments, not stdin) and the user forgot the @@
# placeholder, cov-analysis must behave as if "<cmd> @@" had been given.
#
# Without the auto-@@ behaviour a driver binary invoked without @@ falls into
# stdin-feeding mode, the driver receives no file arguments, and no corpus input
# is ever replayed — so coverage is empty. The fix appends @@ automatically.
#
# Gated on clang/llvm-cov/llvm-profdata/make; skips cleanly when unavailable.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis
set +e   # sourcing cov-analysis enables `set -e`; we capture exit codes by hand

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)

# ── toolchain gate ───────────────────────────────────────────────────────────
CLANG="$(detect_clang || true)"
if test -z "$CLANG" \
   || ! find_tool llvm-cov >/dev/null 2>&1 \
   || ! find_tool llvm-profdata >/dev/null 2>&1 \
   || ! command -v make >/dev/null 2>&1; then
  echo "[SKIP] auto-@@ test (need clang/llvm-cov/llvm-profdata/make)"
  echo "[PASS] test_auto_at_placeholder (skipped)"
  exit 0
fi

# ── build a driver-based coverage binary (driver.c + tests/test.c) ───────────
DRIVER="$TMP/driver.c"
bash ./cov-analysis driver -o "$DRIVER" 2>/dev/null
COV="$TMP/cov"
{
  printf 'cov:\n'
  printf '\t$(CC) $(CFLAGS) $(LDFLAGS) %s %s -o %s\n' "$DRIVER" "tests/test.c" "$COV"
} > "$TMP/Makefile"
bash ./cov-analysis build make -f "$TMP/Makefile" cov >"$TMP/build.log" 2>&1 || {
  cat "$TMP/build.log" >&2; die "build: make invocation failed"
}
test -x "$COV" || die "build: did not produce an executable coverage binary"

# sanity: the binary really carries the driver signature
grep -qaF '###SIGNATURE_LLVMFUZZERTESTONEINPUT_COVERAGE###' "$COV" \
  || die "precondition: built binary lacks the driver signature"

LINE_FA=$(grep -n "Data\[1\] == 'A'" tests/test.c | head -1 | cut -d: -f1)
test -n "$LINE_FA" || die "could not resolve test.c line number"

# ── AFL fixture: FAILS reaches line $LINE_FA; hello does not ─────────────────
AFL="$TMP/out"; mkdir -p "$AFL/queue"
printf 'FAILS' > "$AFL/queue/id:000000,time:0,src:000"
printf 'hello' > "$AFL/queue/id:000001,time:0,src:000"

# ── search WITHOUT @@ must still reach the line (auto-@@ supplied) ───────────
out=$(bash ./cov-analysis search "tests/test.c:$LINE_FA" -d "$AFL" -e "$COV" -q 2>/dev/null)
assert_eq "$(printf '%s\n' "$out" | grep -c 'queue/id:000000')" "1" \
  "search without @@: FAILS must reach line $LINE_FA on a driver binary"
echo "[PASS] search auto-supplies @@ for a driver binary"

# ── report WITHOUT @@ must equal report WITH @@ (both replay the corpus) ──────
REP1="$TMP/rep_at"; REP2="$TMP/rep_noat"
bash ./cov-analysis report -d "$AFL" -e "$COV @@" -o "$REP1" -q 2>/dev/null \
  || die "report with @@: command failed"
bash ./cov-analysis report -d "$AFL" -e "$COV"    -o "$REP2" -q 2>/dev/null \
  || die "report without @@: command failed"
test -s "$REP2/summary.txt" || die "report without @@: missing summary.txt"

# both summaries must be identical — proving the corpus was replayed either way
if ! diff -q "$REP1/summary.txt" "$REP2/summary.txt" >/dev/null; then
  echo "--- with @@ ---";    cat "$REP1/summary.txt"
  echo "--- without @@ ---"; cat "$REP2/summary.txt"
  die "report without @@ produced different coverage than with @@"
fi

# positive guard: the shared result must show test.c with real (non-zero) coverage,
# so the diff above did not pass merely because both runs covered nothing.
grep -q 'test\.c' "$REP2/summary.txt" \
  || die "report without @@: test.c absent from summary (no coverage collected)"
echo "[PASS] report auto-supplies @@ for a driver binary"

echo "[PASS] test_auto_at_placeholder"
