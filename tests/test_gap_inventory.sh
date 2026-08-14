#!/usr/bin/env bash
# Feature test: every report must ship a gap inventory ranked by ABSOLUTE
# uncovered regions.
#
# Field report: the user built this list by hand with
#   llvm-cov report -show-functions <file> | awk '$4=="0.00%"'
# and re-sorted it every time, because a 3,553-region file at 4% holds far more
# uncovered code than an 85-region file at 0% — the ranking a percentage sort
# gets backwards. The fixture below is exactly that pair.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
CORPUS="$TMP/corpus"
mkdir -p "$TOOLS" "$CORPUS"
printf seed > "$CORPUS/seed"

cat > "$TMP/reach.json" <<'EOF'
{"reachable":[{"mangled":"hot_path"},{"mangled":"cold_b"},{"mangled":"dead_one"},
              {"mangled":"dead_two"}],
 "unreachable_defined":[{"mangled":"cold_a"}]}
EOF

cat > "$TMP/target" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
cat > "$TOOLS/llvm-profdata" <<'EOF'
#!/bin/bash
out=""
while test $# -gt 0; do
  if test "$1" = -o; then out="$2"; shift 2; else shift; fi
done
printf merged > "$out"
EOF
cat > "$TOOLS/llvm-cov" <<'EOF'
#!/bin/bash
cmd="$1"
shift
case "$cmd" in
  show)
    out=""; fmt=""
    for arg in "$@"; do case "$arg" in -output-dir=*) out="${arg#*=}";; -format=*) fmt="${arg#*=}";; esac; done
    mkdir -p "$out/coverage"
    if test "$fmt" = html; then
      printf '<html><body><table></table></body></html>\n' > "$out/index.html"
      printf 'body{}\n' > "$out/style.css"
    else
      printf '/src/big.c:\n    1|      1| int hot_path(void);\n' > "$out/coverage/big.txt"
    fi
    ;;
  report)
    perfunc=0
    for arg in "$@"; do test "$arg" = -show-functions && perfunc=1; done
    if test "$perfunc" -eq 1; then
      test "${FAIL_STAGE:-}" = perfunc && exit 12
      cat <<'PERFUNC'
File '/src/big.c':
Name                        Regions    Miss   Cover     Lines    Miss   Cover  Branches    Miss   Cover
-------------------------------------------------------------------------------------------------------
hot_path                        100       0 100.00%        40       0 100.00%        10       0 100.00%
cold_a                         2000    2000   0.00%       700     700   0.00%       200     200   0.00%
cold_b                         1453    1411   2.89%       500     480   4.00%       100      95   5.00%
-------------------------------------------------------------------------------------------------------
TOTAL                          3553    3411   4.00%      1240    1180   4.84%       310     295   4.84%

File '/src/small.c':
Name                        Regions    Miss   Cover     Lines    Miss   Cover  Branches    Miss   Cover
-------------------------------------------------------------------------------------------------------
dead_one                         50      50   0.00%        20      20   0.00%         5       5   0.00%
dead_two                         35      35   0.00%        15      15   0.00%         3       3   0.00%
-------------------------------------------------------------------------------------------------------
TOTAL                            85      85   0.00%        35      35   0.00%         8       8   0.00%
PERFUNC
    else
      cat <<'SUMMARY'
Filename          Regions    Missed Regions     Cover   Functions  Missed Functions  Executed       Lines      Missed Lines     Cover
------------------------------------------------------------------------------------------------------------------------------------
big.c                3553              3411     4.00%           3                 1    66.67%        1240              1180     4.84%
small.c                85                85     0.00%           2                 2     0.00%          35                35     0.00%
------------------------------------------------------------------------------------------------------------------------------------
TOTAL                3638              3496     3.90%           5                 3    40.00%        1275              1215     4.71%
SUMMARY
    fi
    ;;
  export)
    cat <<'JSON'
{"data":[{"files":[{"filename":"/src/big.c","segments":[[1,1,1,true,true]]},
                   {"filename":"/src/small.c","segments":[[1,1,0,true,true]]}],
          "functions":[{"name":"hot_path","count":5,"filenames":["/src/big.c"],"regions":[[1,1,39,1,5,0,0,0]]},
                       {"name":"cold_a","count":0,"filenames":["/src/big.c"],"regions":[[40,1,79,1,0,0,0,0]]},
                       {"name":"cold_b","count":3,"filenames":["/src/big.c"],"regions":[[80,1,119,1,3,0,0,0]]},
                       {"name":"dead_one","count":0,"filenames":["/src/small.c"],"regions":[[1,1,19,1,0,0,0,0]]},
                       {"name":"dead_two","count":0,"filenames":["/src/small.c"],"regions":[[20,1,34,1,0,0,0,0]]}]}]}
JSON
    ;;
esac
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export PATH="$TOOLS:/usr/bin:/bin" CC=/bin/true

report() {
  bash ./cov-analysis report -d "$CORPUS" -e "$TMP/target @@" -o "$1" "${@:2}"
}

# ── plain report ─────────────────────────────────────────────────────────────
DEST="$TMP/report"
out=$(report "$DEST" 2>&1) || die "report failed: $out"
GAPS="$DEST/gaps.txt"
test -s "$GAPS" || die "no gap inventory was published"

# Ranked by absolute uncovered regions: the 4%-covered 3553-region file outranks
# the 0%-covered 85-region file, which a percentage sort gets backwards.
big_at=$(grep -n '/src/big.c' "$GAPS" | head -1 | cut -d: -f1)
small_at=$(grep -n '/src/small.c' "$GAPS" | head -1 | cut -d: -f1)
test -n "$big_at" && test -n "$small_at" || die "gap inventory lists no files: $(cat "$GAPS")"
test "$big_at" -lt "$small_at" \
  || die "files are not ranked by absolute uncovered regions: $(cat "$GAPS")"

grep -q '3411' "$GAPS" || die "big.c uncovered region count missing: $(cat "$GAPS")"
grep -q '3553' "$GAPS" || die "big.c total region count missing: $(cat "$GAPS")"
grep -q '^Filename\|3411' "$DEST/summary.txt" \
  || die "precondition: summary.txt should carry the same numbers"
echo "[PASS] files ranked by absolute uncovered regions"

# ── zero-coverage function inventory ─────────────────────────────────────────
funcs=$(sed -n '/^== Functions with no coverage/,$p' "$GAPS")
printf '%s\n' "$funcs" | grep -q 'cold_a'   || die "zero-coverage function cold_a missing: $funcs"
printf '%s\n' "$funcs" | grep -q 'dead_one' || die "zero-coverage function dead_one missing: $funcs"
printf '%s\n' "$funcs" | grep -q 'dead_two' || die "zero-coverage function dead_two missing: $funcs"
printf '%s\n' "$funcs" | grep -q 'cold_b'   && die "partially covered cold_b must not be listed: $funcs"
printf '%s\n' "$funcs" | grep -q 'hot_path' && die "fully covered hot_path must not be listed: $funcs"
a=$(printf '%s\n' "$funcs" | grep -n 'cold_a'   | head -1 | cut -d: -f1)
b=$(printf '%s\n' "$funcs" | grep -n 'dead_one' | head -1 | cut -d: -f1)
test "$a" -lt "$b" || die "functions are not ranked by uncovered regions: $funcs"
echo "[PASS] zero-coverage functions listed and ranked"

printf '%s\n' "$out" | grep -q 'gaps.txt' || die "report did not point at the gap inventory: $out"
echo "[PASS] the report points at the gap inventory"

# ── reachability splits the actionable gap from the dead code ────────────────
DEST2="$TMP/report-reach"
out=$(report "$DEST2" --reachability "$TMP/reach.json" 2>&1) \
  || die "reachability report failed: $out"
GAPS2="$DEST2/gaps.txt"
actionable=$(sed -n '/^== Functions with no coverage: reachable/,/^== Functions with no coverage: statically/p' "$GAPS2")
dead=$(sed -n '/^== Functions with no coverage: statically/,$p' "$GAPS2")
printf '%s\n' "$actionable" | grep -q 'dead_one' \
  || die "reachable-but-uncovered function is not in the actionable list: $(cat "$GAPS2")"
printf '%s\n' "$actionable" | grep -q 'cold_a' \
  && die "statically unreachable cold_a must not be in the actionable list: $(cat "$GAPS2")"
printf '%s\n' "$dead" | grep -q 'cold_a' \
  || die "statically unreachable cold_a is not in the dead list: $(cat "$GAPS2")"
echo "[PASS] reachability splits actionable gaps from dead code"

# ── a report that cannot build the inventory must not publish ────────────────
cp -a "$DEST" "$TMP/snapshot"
if FAIL_STAGE=perfunc report "$DEST" >"$TMP/perfunc.log" 2>&1; then
  die "a failed per-function report must not publish"
fi
diff -r "$DEST" "$TMP/snapshot" >/dev/null \
  || die "the previous report was modified by the failed run"
echo "[PASS] a report without a gap inventory is not published"

echo "[PASS] test_gap_inventory"
