#!/usr/bin/env bash
# Feature test: N harnesses over one shared library in ONE command.
#
# Field report: 13 campaigns, each with its own binary, all linking one library.
# The user needed per-harness numbers, the union across all of them, and a
# per-file "which harness covers this best" — and hand-rolled roughly twenty
# commands to get it.
#
# Two harnesses reach disjoint halves of lib.c here, so the union must be
# strictly better than either campaign alone.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis
set +e

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
CLANG="$(detect_clang || true)"
if test -z "$CLANG" || ! find_tool llvm-cov >/dev/null 2>&1 \
   || ! find_tool llvm-profdata >/dev/null 2>&1; then
  echo "[SKIP] multi-campaign test (need clang/llvm-cov/llvm-profdata)"
  echo "[PASS] test_multi_campaign (skipped)"
  exit 0
fi
export CC="$CLANG"

DRIVER="$TMP/driver.c"
bash ./cov-analysis driver -o "$DRIVER" >/dev/null
cat > "$TMP/lib.c" <<'EOF'
#include <stddef.h>
int shared_helper(int x) { if (x > 10) return x * 2; return x + 1; }
int parse_a(const unsigned char *d, size_t n) {
  if (n < 1) return -1;
  if (d[0] == 'A') return shared_helper(11);
  return 0;
}
int parse_b(const unsigned char *d, size_t n) {
  if (n < 1) return -1;
  if (d[0] == 'B') return shared_helper(1);
  return 0;
}
int never_used(int q) { return q * 3; }
EOF
cat > "$TMP/ha.c" <<'EOF'
#include <stddef.h>
int parse_a(const unsigned char *, size_t);
int LLVMFuzzerTestOneInput(const unsigned char *d, size_t n) { return parse_a(d, n); }
EOF
cat > "$TMP/hb.c" <<'EOF'
#include <stddef.h>
int parse_b(const unsigned char *, size_t);
int LLVMFuzzerTestOneInput(const unsigned char *d, size_t n) { return parse_b(d, n); }
EOF
"$CLANG" -O0 -g -fprofile-instr-generate -fcoverage-mapping \
  "$DRIVER" "$TMP/lib.c" "$TMP/ha.c" -o "$TMP/cova" 2>"$TMP/cc.log" \
  || { cat "$TMP/cc.log" >&2; die "could not build harness A"; }
"$CLANG" -O0 -g -fprofile-instr-generate -fcoverage-mapping \
  "$DRIVER" "$TMP/lib.c" "$TMP/hb.c" -o "$TMP/covb" 2>"$TMP/cc.log" \
  || { cat "$TMP/cc.log" >&2; die "could not build harness B"; }

mkdir -p "$TMP/outa/queue" "$TMP/outb/queue"
printf A > "$TMP/outa/queue/id:000000,time:0,src:000"
printf B > "$TMP/outb/queue/id:000000,time:0,src:000"

# missed lines for lib.c out of an llvm-cov summary table
missed_lines() {
  awk '$1 ~ /lib\.c$/ { print $(NF-4); exit }' "$1"
}

OUT="$TMP/multi"
out=$(bash ./cov-analysis report \
  -d "$TMP/outa" -e "$TMP/cova @@" --name campa \
  -d "$TMP/outb" -e "$TMP/covb @@" --name campb \
  -o "$OUT" 2>&1) || die "multi-campaign report failed: $out"

test -s "$OUT/campa/summary.txt" || die "campaign A has no report: $out"
test -s "$OUT/campb/summary.txt" || die "campaign B has no report: $out"
test -s "$OUT/union/summary.txt" || die "union has no report: $out"
test -f "$OUT/.cov-analysis-report" || die "multi-campaign output is not a marked artifact"
echo "[PASS] per-campaign reports and a union report are produced"

a_missed=$(missed_lines "$OUT/campa/summary.txt")
b_missed=$(missed_lines "$OUT/campb/summary.txt")
u_missed=$(missed_lines "$OUT/union/summary.txt")
test -n "$a_missed" && test -n "$b_missed" && test -n "$u_missed" \
  || die "could not read lib.c coverage from the summaries"
test "$u_missed" -lt "$a_missed" \
  || die "union ($u_missed missed) is not better than campaign A ($a_missed missed)"
test "$u_missed" -lt "$b_missed" \
  || die "union ($u_missed missed) is not better than campaign B ($b_missed missed)"
echo "[PASS] the union covers strictly more than either campaign alone"

test -s "$OUT/union/gaps.txt" || die "the union has no gap inventory"
grep -q 'never_used' "$OUT/union/gaps.txt" \
  || die "the union gap inventory misses the dead function: $(cat "$OUT/union/gaps.txt")"
echo "[PASS] the gap inventory covers the union"

# ── attribution ──────────────────────────────────────────────────────────────
ATTR="$OUT/attribution.txt"
test -s "$ATTR" || die "no attribution table was produced"
test -s "$OUT/attribution.html" || die "no attribution HTML was produced"
grep -q 'campa' "$ATTR" || die "attribution does not mention campaign A: $(cat "$ATTR")"
grep -q 'campb' "$ATTR" || die "attribution does not mention campaign B: $(cat "$ATTR")"
grep -q 'lib\.c' "$ATTR" || die "attribution does not mention the shared library: $(cat "$ATTR")"

# Each harness reaches lines the other cannot, so both must own unique lines.
# Rows read: "<name> <covered> covered, <unique> unique, <pct>%"
lib_block=$(awk '/lib\.c/ { show = 1; next } /^\// { show = 0 } show' "$ATTR")
uniq_a=$(printf '%s\n' "$lib_block" | awk '$1 == "campa" { print $4 }' | head -1)
uniq_b=$(printf '%s\n' "$lib_block" | awk '$1 == "campb" { print $4 }' | head -1)
test -n "$uniq_a" && test "$uniq_a" -gt 0 \
  || die "campaign A owns no unique lines in lib.c: $(cat "$ATTR")"
test -n "$uniq_b" && test "$uniq_b" -gt 0 \
  || die "campaign B owns no unique lines in lib.c: $(cat "$ATTR")"
echo "[PASS] the attribution table reports per-campaign and unique coverage"

# ── a stale object must not silently under-report ────────────────────────────
cat > "$TMP/lib.c" <<'EOF'
#include <stddef.h>
int shared_helper(int x) { if (x > 10) { if (x > 100) return x; return x * 2; } return x + 1; }
int parse_a(const unsigned char *d, size_t n) {
  if (n < 1) return -1;
  if (d[0] == 'A') return shared_helper(11);
  return 0;
}
int parse_b(const unsigned char *d, size_t n) {
  if (n < 1) return -1;
  if (d[0] == 'B') return shared_helper(1);
  return 0;
}
int never_used(int q) { return q * 3; }
EOF
"$CLANG" -O0 -g -fprofile-instr-generate -fcoverage-mapping \
  "$DRIVER" "$TMP/lib.c" "$TMP/hb.c" -o "$TMP/covb" 2>/dev/null \
  || die "could not rebuild harness B"
out=$(bash ./cov-analysis report \
  -d "$TMP/outa" -e "$TMP/cova @@" --name campa \
  -d "$TMP/outb" -e "$TMP/covb @@" --name campb \
  -o "$TMP/multi2" 2>&1)
printf '%s\n' "$out" | grep -qi 'mismatch' \
  || die "a coverage-mapping mismatch between campaign binaries was not reported: $out"
echo "[PASS] mismatched campaign binaries are reported, not silently dropped"

# ── one campaign keeps the classic single-report layout ──────────────────────
SINGLE="$TMP/single"
bash ./cov-analysis report -d "$TMP/outa" -e "$TMP/cova @@" -o "$SINGLE" -q \
  >"$TMP/single.log" 2>&1 || die "single-campaign report failed: $(cat "$TMP/single.log")"
test -s "$SINGLE/summary.txt" || die "single-campaign report lost its summary"
test -e "$SINGLE/union" && die "a single campaign must not grow a union subdirectory"
test -e "$SINGLE/attribution.txt" && die "a single campaign must not produce attribution"
echo "[PASS] a single -d/-e pair is unchanged"

echo "[PASS] test_multi_campaign"
