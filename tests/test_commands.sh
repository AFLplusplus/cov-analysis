#!/usr/bin/env bash
# End-to-end integration test exercising every cov-analysis command against the
# tests/test.c LLVMFuzzerTestOneInput target (a magic-value NULL-deref crash on
# inputs of the form "FA$$$"). Gated on clang/llvm-cov/llvm-profdata/make; skips
# cleanly (exit 0) when the toolchain is unavailable.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)

# ── toolchain gate ───────────────────────────────────────────────────────────
CLANG="$(detect_clang || true)"
if test -z "$CLANG" \
   || ! find_tool llvm-cov >/dev/null 2>&1 \
   || ! find_tool llvm-profdata >/dev/null 2>&1 \
   || ! command -v make >/dev/null 2>&1; then
  echo "[SKIP] commands integration test (need clang/llvm-cov/llvm-profdata/make)"
  echo "[PASS] test_commands (skipped)"
  exit 0
fi

# ── command: driver — emit the replay driver and verify it carries the signature
DRIVER="$TMP/driver.c"
bash ./cov-analysis driver -o "$DRIVER" 2>/dev/null
test -s "$DRIVER" || die "driver: emitted file is empty"
grep -qF '###SIGNATURE_LLVMFUZZERTESTONEINPUT_COVERAGE###' "$DRIVER" \
  || die "driver: emitted driver lacks the batch-mode signature"
echo "[PASS] driver"

# ── command: build — set coverage flags and build the binary via a Makefile ──
# (the emitted driver + tests/test.c, compiled through `cov-analysis build make`)
COV="$TMP/cov"
{
  printf 'cov:\n'
  printf '\t$(CC) $(CFLAGS) $(LDFLAGS) %s %s -o %s\n' "$DRIVER" "tests/test.c" "$COV"
} > "$TMP/Makefile"

bash ./cov-analysis build make -f "$TMP/Makefile" cov >"$TMP/build.log" 2>&1 || {
  cat "$TMP/build.log" >&2; die "build: make invocation failed"
}
test -x "$COV" || die "build: did not produce an executable coverage binary"

# build must export the coverage flags into the child environment.
flags=$(bash ./cov-analysis build sh -c 'printf "%s" "$CFLAGS"' 2>/dev/null)
case "$flags" in
  *-fprofile-instr-generate*) ;;
  *) die "build: CFLAGS missing -fprofile-instr-generate (got '$flags')" ;;
esac
case "$flags" in
  *-fcoverage-mapping*) ;;
  *) die "build: CFLAGS missing -fcoverage-mapping (got '$flags')" ;;
esac
echo "[PASS] build"

# ── AFL fixture ──────────────────────────────────────────────────────────────
# queue: FAILS (reaches the Data[1]=='A' branch, no crash), hello (no F branch)
# crashes: FA$$$ (reaches and crashes at the *foo=1 line)
AFL="$TMP/out"; mkdir -p "$AFL/queue" "$AFL/crashes" "$AFL/timeouts"
printf 'FAILS' > "$AFL/queue/id:000000,time:0,src:000"      # F,A,I -> reaches line 12, not 15
printf 'hello' > "$AFL/queue/id:000001,time:0,src:000"      # no 'F' -> does not reach line 12
printf 'FA$$$' > "$AFL/crashes/id:000000,sig:11,src:000"    # F,A,$,$,$ -> crashes at line 15

LINE_FA=$(grep -n "Data\[1\] == 'A'" tests/test.c | head -1 | cut -d: -f1)   # 12
LINE_CRASH=$(grep -n '\*foo = 1' tests/test.c | head -1 | cut -d: -f1)       # 15
test -n "$LINE_FA" && test -n "$LINE_CRASH" || die "could not resolve test.c line numbers"

# ── command: report — produce the full report set (queue batch + crash replay)
REP="$TMP/rep"
bash ./cov-analysis report -d "$AFL" -e "$COV @@" -o "$REP" -q 2>/dev/null \
  || die "report: command failed"
test -f "$REP/html/index.html" || die "report: missing html/index.html"
test -s "$REP/summary.txt"     || die "report: missing summary.txt"
test -s "$REP/coverage.json"   || die "report: missing coverage.json"
test -s "$REP/coverage.profdata" || die "report: missing coverage.profdata"
echo "[PASS] report"

# ── command: search ──────────────────────────────────────────────────────────
# queue-only: line 12 is reached by FAILS, not by hello.
out=$(bash ./cov-analysis search "tests/test.c:$LINE_FA" -d "$AFL" -e "$COV @@" -q 2>/dev/null)
assert_eq "$(printf '%s\n' "$out" | grep -c 'queue/id:000000')" "1" "search: FAILS reaches line $LINE_FA"
assert_eq "$(printf '%s\n' "$out" | grep -c 'queue/id:000001')" "0" "search: hello excluded at line $LINE_FA"
assert_eq "$(printf '%s\n' "$out" | grep -c 'crashes/')"        "0" "search: crashes excluded without --crashes"

# --crashes: line 12 is reached by FAILS (queue) AND FA$$$ (crash).
out=$(bash ./cov-analysis search "tests/test.c:$LINE_FA" -d "$AFL" -e "$COV @@" --crashes -t 4 -q 2>/dev/null)
assert_eq "$(printf '%s\n' "$out" | grep -c 'queue/id:000000')"   "1" "search --crashes: FAILS reaches line $LINE_FA"
assert_eq "$(printf '%s\n' "$out" | grep -c 'crashes/id:000000')" "1" "search --crashes: crash reaches line $LINE_FA"

# queue-only: the crash line is executable but unreached -> 0 matches + helpful note.
out=$(bash ./cov-analysis search "tests/test.c:$LINE_CRASH" -d "$AFL" -e "$COV @@" 2>"$TMP/serr")
assert_eq "$(printf '%s' "$out" | grep -c .)" "0" "search: crash line unreached by queue"
grep -q 'no selected input reaches it' "$TMP/serr" || die "search: missing 'executable but unreached' note"
grep -q -- '--crashes' "$TMP/serr" || die "search: missing --crashes retry hint"

# --crashes: the crash input reaches the crash line.
out=$(bash ./cov-analysis search "tests/test.c:$LINE_CRASH" -d "$AFL" -e "$COV @@" --crashes -q 2>/dev/null)
assert_eq "$(printf '%s\n' "$out" | grep -c 'crashes/id:000000')" "1" "search --crashes: crash reaches crash line"
assert_eq "$(printf '%s\n' "$out" | grep -c 'queue/')"            "0" "search --crashes: queue excluded at crash line"
echo "[PASS] search"

# ── command: stability — deterministic harness must be perfectly stable ──────
out=$(bash ./cov-analysis stability -d "$AFL" -e "$COV @@" 2>&1) || die "stability: command failed"
printf '%s\n' "$out" | grep -q 'perfectly stable' \
  || die "stability: expected a perfectly-stable result for a deterministic target"
echo "[PASS] stability"

# ── command: diff — two reports (small vs full) into the same dir, then diff ─
# `cov-analysis diff` runs its embedded report via `python3 -`. Gate on that
# capability so the suite stays green where python3 is absent or shimmed (e.g.
# tooling that intercepts `python3 -` and demands `uv run`).
if printf 'pass\n' | python3 - >/dev/null 2>&1; then
  AFL_SMALL="$TMP/out_small"; mkdir -p "$AFL_SMALL/queue"
  printf 'hello' > "$AFL_SMALL/queue/id:000000,time:0,src:000"
  DREP="$TMP/drep"
  bash ./cov-analysis report -d "$AFL_SMALL" -e "$COV @@" -o "$DREP" -q 2>/dev/null \
    || die "diff setup: baseline report failed"
  bash ./cov-analysis report -d "$AFL"       -e "$COV @@" -o "$DREP" -q 2>/dev/null \
    || die "diff setup: updated report failed"
  test -s "$DREP/coverage_old.json" || die "diff setup: coverage_old.json not created on re-run"
  bash ./cov-analysis diff -o "$DREP" >/dev/null 2>&1 || die "diff: command failed"
  test -s "$DREP/coverage_diff.html" || die "diff: coverage_diff.html not produced"
  grep -qi '<html' "$DREP/coverage_diff.html" || die "diff: output is not HTML"
  echo "[PASS] diff"
else
  echo "[SKIP] diff (python3 cannot execute a stdin script in this environment)"
fi

echo "[PASS] test_commands"
