#!/usr/bin/env bash
# tests/test_reachability_cpp_e2e.sh — C++ keystone round-trip: fuzz-reachability's
# static analysis of a deliberately adversarial C++ harness (every indirect-call
# flavor, plus red-herring and genuinely-dead functions) cross-referenced against
# a real -fprofile-instr-generate/-fcoverage-mapping build replayed through
# llvm-cov, via cov-analysis's own `report --reachability`. Nothing is synthetic:
# the reachability side is built with gllvm/get-bc, the coverage side with clang++,
# and the join between the two independently-built modules is by exact Itanium C++
# name (the fixture is built without -g, so reach.json carries no file/line and the
# (file,line) fallback structurally cannot fire).
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
COV="$(pwd)/cov-analysis"

FIXTURE="${FUZZ_REACH_FIXTURE:-/prg/fuzz-reachability/fixtures/cpp_complex}"
REACH_CLI="${FUZZ_REACH_CLI:-/prg/fuzz-reachability/driver/.venv/bin/reachability}"
ANALYZER="${FUZZ_REACH_ANALYZER:-/prg/fuzz-reachability/analyzer/build/reachability-analyzer}"

PY=""
for cand in python3 /usr/bin/python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import json,sys' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ]         || { echo "[SKIP] no working python3"; exit 0; }
[ -f "$FIXTURE/main.cpp" ] || { echo "[SKIP] fixtures/cpp_complex not found (fuzz-reachability checkout missing)"; exit 0; }
[ -x "$REACH_CLI" ]  || { echo "[SKIP] reachability driver venv not found: $REACH_CLI"; exit 0; }
[ -x "$ANALYZER" ]   || { echo "[SKIP] reachability-analyzer binary not built: $ANALYZER"; exit 0; }
command -v make >/dev/null 2>&1 || { echo "[SKIP] make not available"; exit 0; }
for t in gclang gclang++ get-bc; do
  command -v "$t" >/dev/null 2>&1 || { echo "[SKIP] gllvm ($t) not available (C/C++ bitcode acquisition)"; exit 0; }
done

CLANG="$(detect_clang || true)"
[ -n "$CLANG" ] || { echo "[SKIP] clang not available"; exit 0; }
ver="${CLANG#clang}"; ver="${ver#-}"
CLANGXX="clang++${ver:+-$ver}"
command -v "$CLANGXX" >/dev/null 2>&1 || CLANGXX="clang++"
command -v "$CLANGXX" >/dev/null 2>&1 || { echo "[SKIP] clang++ not available"; exit 0; }
COVTOOL=""; for c in "llvm-cov${ver:+-$ver}" llvm-cov; do command -v "$c" >/dev/null 2>&1 && { COVTOOL="$c"; break; }; done
PROFDATA=""; for p in "llvm-profdata${ver:+-$ver}" llvm-profdata; do command -v "$p" >/dev/null 2>&1 && { PROFDATA="$p"; break; }; done
[ -n "$COVTOOL" ]  || { echo "[SKIP] llvm-cov not available"; exit 0; }
[ -n "$PROFDATA" ] || { echo "[SKIP] llvm-profdata not available"; exit 0; }

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)
WORK="$TMP/work"
mkdir -p "$WORK"
cp "$FIXTURE/main.cpp" "$FIXTURE/Makefile" "$WORK/"

# ── stage 1: static reachability analysis of the C++ harness ────────────────
REACHABILITY_ANALYZER="$ANALYZER" "$REACH_CLI" run --lang cpp --project "$WORK" \
  --entry LLVMFuzzerTestOneInput --out "$WORK/reach.json" > "$TMP/reach_run.log" 2>&1 \
  || die "reachability run failed: $(cat "$TMP/reach_run.log")"
[ -f "$WORK/reach.json" ]      || die "reach.json was not produced"
[ -f "$WORK/reached.txt" ]     || die "reached.txt was not produced"
[ -f "$WORK/not_reached.txt" ] || die "not_reached.txt was not produced"

read -r N_DEFINED N_REACHABLE N_UNREACHABLE FILE_NULL < <("$PY" - "$WORK/reach.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d['summary']
recs = d['reachable'] + d.get('unreachable_defined', [])
print(s['defined'], s['reachable'], s['unreachable'], int(all(r.get('file') is None for r in recs)))
PY
)
# Raw counts scale with clang++/libstdc++ template/coroutine emission, so bound
# them and assert self-consistency; the named-membership greps below are the real
# reachable-vs-unreachable correctness anchors (the analyzer repo pins the exact
# counts against its own expected.json).
[ "$N_DEFINED" -ge 150 ]   || die "reach.json summary.defined implausibly low ($N_DEFINED)"
[ "$N_REACHABLE" -ge 140 ] || die "reach.json summary.reachable implausibly low ($N_REACHABLE)"
[ "$N_UNREACHABLE" -ge 8 ] || die "reach.json summary.unreachable implausibly low ($N_UNREACHABLE)"
assert_eq "$N_REACHABLE" "$((N_DEFINED - N_UNREACHABLE))" "reach.json summary self-consistency (reachable == defined - unreachable)"
assert_eq "$FILE_NULL" "1" "reach.json carries no debug file/line (fixture built without -g), so the reach<->cov join below can only be by exact C++ name"
grep -q 'fun:LLVMFuzzerTestOneInput' "$WORK/reached.txt" || die "reached.txt missing the entry LLVMFuzzerTestOneInput"
grep -q 'fun:_ZL13fnptr_add_onei'    "$WORK/reached.txt" || die "reached.txt missing a real mechanism function (fnptr_add_one)"
for u in _Z16unreachable_leafv _Z15unreachable_midv _Z16unreachable_rootv _Z22unreachable_calls_realv; do
  grep -q "fun:$u" "$WORK/not_reached.txt" || die "not_reached.txt missing genuinely-dead function $u"
done
echo "[PASS] stage 1: static reachability analysis (defined=$N_DEFINED reachable=$N_REACHABLE unreachable=$N_UNREACHABLE; dead cluster unreachable, mechanisms reachable)"

# ── stage 2: real source-based coverage build of the SAME harness ───────────
"$CLANGXX" -O0 -fno-inline -fcoroutines -std=c++20 -Wno-unused-command-line-argument \
  -fprofile-instr-generate -fcoverage-mapping -c "$WORK/main.cpp" -o "$WORK/covmain.o" \
  || die "compiling the coverage main.o failed"
bash "$COV" driver -o "$WORK/coverage_driver.c" >/dev/null || die "cov-analysis driver failed"
"$CLANG" -fprofile-instr-generate -fcoverage-mapping -c "$WORK/coverage_driver.c" -o "$WORK/coverage_driver.o" \
  || die "compiling coverage_driver.c failed"
"$CLANGXX" -fprofile-instr-generate -rdynamic "$WORK/coverage_driver.o" "$WORK/covmain.o" \
  -o "$WORK/cov" -lpthread -ldl || die "linking the cov replay binary failed"
LLVM_PROFILE_FILE="$TMP/sig.profraw" "$WORK/cov" --printsignature \
  | grep -q '###SIGNATURE_LLVMFUZZERTESTONEINPUT_COVERAGE###' \
  || die "cov binary does not carry the cov-analysis driver signature"
echo "[PASS] stage 2: coverage-instrumented binary linked (cov-analysis driver + clang++ main.o)"

# ── stage 3: a controlled corpus that reaches two mechanisms, not the rest ──
mkdir -p "$WORK/corpus"
printf '\x00\x01\x2a' > "$WORK/corpus/sel0_addone"   # selector 0, odd d1 -> fnptr_add_one
printf '\x06\x00\x2a' > "$WORK/corpus/sel6_square"   # selector 6, even d1 -> virtual_Square

# ── stage 4: cov-analysis drives llvm-cov + joins reach.json by C++ name ─────
PATH=/usr/bin:$PATH bash "$COV" report -d "$WORK/corpus" -e "$WORK/cov @@" \
  --reachability "$WORK/reach.json" -o "$WORK/covout" > "$TMP/report.log" 2>&1 \
  || die "cov-analysis report failed: $(cat "$TMP/report.log")"
[ -f "$WORK/covout/coverage.json" ] || die "covout/coverage.json was not produced"

read -r C_ADDONE C_SQUARE C_TIMESTWO C_PLT C_DEAD < <("$PY" - "$WORK/covout/coverage.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
f = {fn['name']: int(fn['count']) for o in d['data'] for fn in o['functions']}
def g(*subs):
    for name, c in f.items():
        if all(s in name for s in subs):
            return c
    return -1
print(g('fnptr_add_one'), g('virtual_Square', 'describe'), g('fnptr_times_two'), g('plt_external_call'), g('unreachable_leaf'))
PY
)
[ "$C_ADDONE" -gt 0 ] || die "coverage: fnptr_add_one should be covered by seed sel0 (got $C_ADDONE)"
[ "$C_SQUARE" -gt 0 ] || die "coverage: virtual_Square::describe should be covered by seed sel6 (got $C_SQUARE)"
assert_eq "$C_TIMESTWO" "0" "coverage: fnptr_times_two is reachable but not exercised by the corpus (amber)"
assert_eq "$C_PLT" "0" "coverage: plt_external_call (selector 16, absent from corpus) is reachable-unreached (amber)"
assert_eq "$C_DEAD" "0" "coverage: unreachable_leaf is statically dead and must never be covered"
echo "[PASS] stage 4: per-function coverage counters correct (fnptr_add_one/virtual_Square covered; fnptr_times_two/plt_external_call/unreachable_leaf uncovered)"

# ── stage 5: reachability tally + recomputed function/line counters ─────────
# A baseline report (no --reachability) gives llvm-cov's full main.cpp numbers;
# the reachable-only table must equal those minus exactly the unreachable set.
PATH=/usr/bin:$PATH bash "$COV" report -d "$WORK/corpus" -e "$WORK/cov @@" \
  -o "$WORK/covout_base" > "$TMP/report_base.log" 2>&1 \
  || die "baseline cov-analysis report failed: $(cat "$TMP/report_base.log")"

read -r T_REACH T_UNREACH T_ANOM EXCL FULL_FN FULL_COV FULL_LN RO_FN RO_COV RO_LN < <("$PY" - "$WORK/covout_base/summary.txt" "$WORK/covout/summary.txt" <<'PY'
import re, sys
base = open(sys.argv[1]).read()
reach = open(sys.argv[2]).read()
def num(pat, txt):
    m = re.search(pat, txt, re.M); return m.group(1) if m else 'NA'
t_reach = num(r'^\s*reachable functions\s*:\s*(\d+)', reach)
t_unreach = num(r'^\s*unreachable functions\s*:\s*(\d+)', reach)
t_anom = num(r'^\s*covered yet unreachable\s*:\s*(\d+)', reach)
excl = num(r'excludes (\d+) statically-unreachable', reach)
# baseline: llvm-cov columnar 'Regions Missed % Functions Missed % Lines Missed % ...'
b = re.search(r'^\S*main\.cpp\S*\s+\d+\s+\d+\s+[\d.]+%\s+(\d+)\s+(\d+)\s+[\d.]+%\s+(\d+)\s+\d+\s+[\d.]+%', base, re.M)
full_fn, full_missed_fn, full_ln = b.group(1), b.group(2), b.group(3)
full_cov = str(int(full_fn) - int(full_missed_fn))
# reachable-only: recomputed 'NN.NN% (cov/denom)' cells (Functions then Lines)
r = re.search(r'main\.cpp\S*\s+[\d.]+% \((\d+)/(\d+)\)\s+[\d.]+% \((\d+)/(\d+)\)', reach)
ro_fn, ro_cov, ro_ln = r.group(2), r.group(1), r.group(4)
print(t_reach, t_unreach, t_anom, excl, full_fn, full_cov, full_ln, ro_fn, ro_cov, ro_ln)
PY
)
# Tallies scale with the toolchain, so bound them; the exact join proof is the
# FULL-minus-reachable-only relations below (invariant of clang/corpus version).
[ "$T_UNREACH" -ge 4 ] || die "summary.txt unreachable tally too low ($T_UNREACH); the gnu::used dead cluster should always be present in coverage"
[ "$T_ANOM" -ge 1 ]    || die "summary.txt covered-yet-unreachable tally should include the load-time static-init/ifunc functions ($T_ANOM)"
[ "$T_REACH" -ge 50 ]  || die "summary.txt should report the reachable functions present in coverage data (got $T_REACH)"
assert_eq "$EXCL" "$T_UNREACH" "summary.txt 'excludes N statically-unreachable' note must equal the unreachable tally"
# the recomputed reachable-only denominator drops exactly the unreachable functions
assert_eq "$((FULL_FN - RO_FN))" "$T_UNREACH" "reachable-only function denominator excludes exactly the unreachable functions ($FULL_FN full -> $RO_FN reachable-only)"
# the recomputed reachable-only numerator drops exactly the covered-yet-unreachable (anomaly) functions
assert_eq "$((FULL_COV - RO_COV))" "$T_ANOM" "reachable-only covered-function numerator excludes exactly the covered-yet-unreachable functions ($FULL_COV covered -> $RO_COV reachable-covered)"
# the recomputed reachable-only line denominator drops the unreachable functions' lines (>= one line per excluded function)
[ "$((FULL_LN - RO_LN))" -ge "$T_UNREACH" ] || die "reachable-only line denominator ($RO_LN) must drop the $T_UNREACH unreachable functions' lines from the full main.cpp total ($FULL_LN)"
grep -qi 'Reachable-only coverage' "$WORK/covout/summary.txt" || die "summary.txt should carry the reachable-only recomputed table"
echo "[PASS] stage 5: reachability tally (reachable=$T_REACH unreachable=$T_UNREACH anomaly=$T_ANOM); recomputed counters drop exactly the dead/anomaly set (functions $FULL_FN->$RO_FN, lines $FULL_LN->$RO_LN)"

# actionable list = reachable but not covered; virtual_Circle (we only hit Square) and fnptr_times_two must be in it
sed -n '/Reachable but NOT reached/,$p' "$WORK/covout/summary.txt" | grep -q '_ZN14virtual_Circle8describeEv' \
  || die "actionable list should include the unreached-but-reachable virtual_Circle::describe"
sed -n '/Reachable but NOT reached/,$p' "$WORK/covout/summary.txt" | grep -q 'fnptr_times_twoi' \
  || die "actionable list should include the unreached-but-reachable fnptr_times_two"
echo "[PASS] stage 5: actionable (reachable-but-unreached) list names the uncovered mechanism functions"

# ── stage 6: HTML banner + per-line annotation (grey/amber/covered) ─────────
IDX="$WORK/covout/html/index.html"
grep -q 'reach-banner' "$IDX"                        || die "index.html should gain a reachability banner"
grep -q "$T_UNREACH unreachable" "$IDX"              || die "index.html banner should report $T_UNREACH unreachable functions"
grep -q "$T_ANOM covered-yet-unreachable" "$IDX"     || die "index.html banner should report $T_ANOM covered-yet-unreachable functions"
HFILE="$(find "$WORK/covout/html/coverage" -name 'main.cpp.html' | head -1)"
[ -n "$HFILE" ] || die "no main.cpp.html found under covout/html/coverage"
DEAD_LINE=$(grep -n 'unreachable_leaf(void)'     "$WORK/main.cpp" | head -1 | cut -d: -f1)
AMBER_LINE=$(grep -n 'plt_external_call(const char' "$WORK/main.cpp" | head -1 | cut -d: -f1)
COV_LINE=$(grep -n 'int fnptr_add_one(int'       "$WORK/main.cpp" | head -1 | cut -d: -f1)
[ -n "$DEAD_LINE" ] && [ -n "$AMBER_LINE" ] && [ -n "$COV_LINE" ] || die "could not locate fixture source lines"
grep -q "reach-grey'><td class='line-number'><a name='L$DEAD_LINE'" "$HFILE" \
  || die "main.cpp.html: unreachable_leaf (line $DEAD_LINE) should tint reach-grey"
grep -qE "class='reach-amber[a-z-]*'><td class='line-number'><a name='L$AMBER_LINE'" "$HFILE" \
  || die "main.cpp.html: plt_external_call (line $AMBER_LINE) should tint amber (reachable-unreached)"
if grep -q "class='reach-[a-z-]*'><td class='line-number'><a name='L$COV_LINE'" "$HFILE"; then
  die "main.cpp.html: covered fnptr_add_one (line $COV_LINE) must NOT carry any reach-* tint"
fi
echo "[PASS] stage 6: per-line tint correct (unreachable_leaf grey, plt_external_call amber, covered fnptr_add_one untinted)"

echo "[PASS] test_reachability_cpp_e2e"
