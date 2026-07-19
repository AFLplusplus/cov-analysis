#!/usr/bin/env bash
# tests/test_reachability_ziggy_e2e.sh — cargo-ziggy keystone round-trip:
# fuzz-reachability analyses a real cargo-ziggy fuzz target (rooted at `main` via
# the `ziggy::fuzz!` closure, the ziggy entry) with `--lang ziggy --mangling v0`,
# then cov-analysis cross-references a real `-Cinstrument-coverage` (v0) build of
# the same crate replayed through llvm-cov.
#
# The twist this exercises: both sides are v0, but the two builds are independent
# (`cargo ziggy build` vs a plain `cargo build`), so the v0 crate-disambiguator
# hash DRIFTS between them and the crate functions do NOT match by name/key. The
# join is carried by the (file,line) fallback (both builds carry debug info),
# while the exported #[no_mangle] functions (stable names) match by name -- proven
# in stage 6 by nulling file/line and watching the crate-function join collapse
# while the #[no_mangle] dead set stays classified.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
COV="$(pwd)/cov-analysis"

FIXTURE="${FUZZ_REACH_FIXTURE:-/prg/fuzz-reachability/fixtures/rust_indirect}"
REACH_CLI="${FUZZ_REACH_CLI:-/prg/fuzz-reachability/driver/.venv/bin/reachability}"
ANALYZER="${FUZZ_REACH_ANALYZER:-/prg/fuzz-reachability/analyzer/build/reachability-analyzer}"

PY=""
for cand in python3 /usr/bin/python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import json,sys' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ]         || { echo "[SKIP] no working python3"; exit 0; }
[ -f "$FIXTURE/src/main.rs" ] || { echo "[SKIP] fixtures/rust_indirect not found (fuzz-reachability checkout missing)"; exit 0; }
[ -x "$REACH_CLI" ]  || { echo "[SKIP] reachability driver venv not found: $REACH_CLI"; exit 0; }
[ -x "$ANALYZER" ]   || { echo "[SKIP] reachability-analyzer binary not built: $ANALYZER"; exit 0; }
command -v cargo >/dev/null 2>&1 || { echo "[SKIP] cargo not available"; exit 0; }
command -v rustc >/dev/null 2>&1 || { echo "[SKIP] rustc not available"; exit 0; }
cargo ziggy --version >/dev/null 2>&1 || { echo "[SKIP] cargo-ziggy not available"; exit 0; }
cargo afl --version   >/dev/null 2>&1 || { echo "[SKIP] cargo-afl not available (cargo ziggy build needs it)"; exit 0; }

CLANG="$(detect_clang || true)"
ver=""; [ -n "$CLANG" ] && { ver="${CLANG#clang}"; ver="${ver#-}"; }
COVTOOL=""; for c in "llvm-cov${ver:+-$ver}" llvm-cov; do command -v "$c" >/dev/null 2>&1 && { COVTOOL="$c"; break; }; done
PROFDATA=""; for p in "llvm-profdata${ver:+-$ver}" llvm-profdata; do command -v "$p" >/dev/null 2>&1 && { PROFDATA="$p"; break; }; done
[ -n "$COVTOOL" ]  || { echo "[SKIP] llvm-cov not available"; exit 0; }
[ -n "$PROFDATA" ] || { echo "[SKIP] llvm-profdata not available"; exit 0; }

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)
WORK="$TMP/work"
mkdir -p "$WORK"
cp -r "$FIXTURE/Cargo.toml" "$FIXTURE/build.rs" "$FIXTURE/src" "$WORK/"

# ── stage 1: static reachability analysis of the cargo-ziggy target (v0) ────
if ! REACHABILITY_ANALYZER="$ANALYZER" "$REACH_CLI" run --lang ziggy --project "$WORK" \
  --mangling v0 --out "$WORK/reach.json" > "$TMP/reach_run.log" 2>&1; then
  if grep -qiE 'bundled LLVM|bitcode cannot be read|LLVM_MAJOR' "$TMP/reach_run.log"; then
    echo "[SKIP] reachability analyzer/rustc LLVM toolchain mismatch: $(tail -n1 "$TMP/reach_run.log")"; exit 0
  fi
  if grep -qiE 'plugins are not installed|AFL_.*plugin' "$TMP/reach_run.log"; then
    echo "[SKIP] cargo-afl plugins not installed for this rustc: $(tail -n1 "$TMP/reach_run.log")"; exit 0
  fi
  die "reachability run failed: $(cat "$TMP/reach_run.log")"
fi
[ -f "$WORK/reach.json" ]      || die "reach.json was not produced"
[ -f "$WORK/reached.txt" ]     || die "reached.txt was not produced"
[ -f "$WORK/not_reached.txt" ] || die "not_reached.txt was not produced"

read -r MANGLING N_DEFINED N_REACHABLE N_UNREACHABLE N_WITH_LOC HE DL FC U1 U2 U3 U4 LLVMF < <("$PY" - "$WORK/reach.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d['summary']
R = {f['demangled'] for f in d['reachable']} | {f['mangled'] for f in d['reachable']}
U = {f['demangled'] for f in d.get('unreachable_defined', [])} | {f['mangled'] for f in d.get('unreachable_defined', [])}
with_loc = sum(1 for f in d['reachable'] if f.get('file'))
def r(name): return int(name in R)
def u(name): return int(name in U)
print(d.get('mangling'), s['defined'], s['reachable'], s['unreachable'], with_loc,
      r('rust_ziggy_indirect_calls::harness_entry'),
      r('dlsym_resolved_target'),
      r('rust_ziggy_indirect_calls::fnptr_call'),
      u('unreachable_fnptr_dead'), u('unreachable_trait_object_dead'),
      u('unreachable_raw_waker_dead'), u('unreachable_redherings_direct_dead'),
      u('LLVMFuzzerTestOneInput'))
PY
)
assert_eq "$MANGLING" "v0" "reach.json top-level mangling field"
[ "$N_DEFINED" -ge 1000 ]   || die "reach.json summary.defined implausibly low ($N_DEFINED)"
[ "$N_REACHABLE" -ge 500 ]  || die "reach.json summary.reachable implausibly low ($N_REACHABLE)"
[ "$N_UNREACHABLE" -ge 200 ] || die "reach.json summary.unreachable implausibly low ($N_UNREACHABLE)"
[ "$N_WITH_LOC" -ge 100 ]   || die "reach.json reachable records should carry debug file/line (needed for the (file,line) fallback); only $N_WITH_LOC did"
assert_eq "$HE" "1" "harness_entry reachable from the ziggy::fuzz! entry (main)"
assert_eq "$DL" "1" "dlsym_resolved_target reachable (runtime dlsym edge)"
assert_eq "$FC" "1" "fnptr_call reachable (indirect-call mechanism)"
assert_eq "$U1" "1" "unreachable_fnptr_dead is dead (no edge from harness_entry)"
assert_eq "$U2" "1" "unreachable_trait_object_dead is dead"
assert_eq "$U3" "1" "unreachable_raw_waker_dead is dead"
assert_eq "$U4" "1" "unreachable_redherings_direct_dead is dead"
assert_eq "$LLVMF" "1" "LLVMFuzzerTestOneInput is unreachable (the ziggy entry is main, not the libFuzzer symbol)"
grep -q 'fun:unreachable_fnptr_dead' "$WORK/not_reached.txt"     || die "not_reached.txt missing #[no_mangle] unreachable_fnptr_dead"
grep -q 'fun:LLVMFuzzerTestOneInput' "$WORK/not_reached.txt"     || die "not_reached.txt missing LLVMFuzzerTestOneInput"
grep -qE 'fun:_R.*harness_entry'     "$WORK/reached.txt"         || die "reached.txt missing a v0-mangled harness_entry entry"
echo "[PASS] stage 1: static reachability (v0, defined=$N_DEFINED reachable=$N_REACHABLE unreachable=$N_UNREACHABLE; harness_entry reachable, dead set + LLVMFuzzerTestOneInput unreachable)"

# ── stage 2: real -Cinstrument-coverage (v0) build of the SAME crate ────────
( cd "$WORK" && FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1 \
    RUSTFLAGS="-Cinstrument-coverage -Copt-level=0" cargo build > "$TMP/covbuild.log" 2>&1 ) \
  || die "coverage cargo build failed: $(cat "$TMP/covbuild.log")"
BIN="$WORK/target/debug/rust_ziggy_indirect_calls"
[ -x "$BIN" ] || die "coverage binary was not built: $BIN"
# ziggy's fuzz! macro, built outside the fuzzer, replays a single input file arg
printf '\x00' > "$WORK/probe"
LLVM_PROFILE_FILE="$TMP/probe.profraw" "$BIN" "$WORK/probe" > "$TMP/probe.log" 2>&1 \
  || die "ziggy coverage bin failed to replay a file argument (reproduce mode): $(cat "$TMP/probe.log")"
[ -s "$TMP/probe.profraw" ] || die "ziggy coverage bin produced no profraw"
echo "[PASS] stage 2: coverage-instrumented ziggy bin built (v0) and replays a single input file"

# ── stage 3: a controlled corpus that reaches two selectors, not the rest ───
mkdir -p "$WORK/corpus"
printf '\x00'     > "$WORK/corpus/sel0"   # selector 0 -> fnptr_call -> fnptr_target_add
printf '\x05\x02' > "$WORK/corpus/sel5"   # selector 5 -> method_pointer_call

# ── stage 4: cov-analysis drives llvm-cov + joins the v0 reach.json ─────────
if ! PATH=/usr/bin:$PATH bash "$COV" report -d "$WORK/corpus" -e "$BIN @@" \
  --reachability "$WORK/reach.json" -o "$WORK/covout" > "$TMP/report.log" 2>&1; then
  if grep -qiE 'unsupported.*version|malformed|profile.*version|raw profile' "$TMP/report.log"; then
    echo "[SKIP] llvm-cov/llvm-profdata vs rustc-LLVM profile-format skew: $(tail -n1 "$TMP/report.log")"; exit 0
  fi
  die "cov-analysis report failed: $(cat "$TMP/report.log")"
fi
[ -f "$WORK/covout/coverage.json" ] || die "covout/coverage.json was not produced"

read -r C_ADD C_MPC C_TOV C_DEAD DRIFT < <("$PY" - "$WORK/covout/coverage.json" "$WORK/reach.json" <<'PY'
import json, re, sys
cov = json.load(open(sys.argv[1]))
reach = json.load(open(sys.argv[2]))
f = {fn['name']: int(fn['count']) for o in cov['data'] for fn in o['functions']}
def g(*subs):
    for name, c in f.items():
        if all(s in name for s in subs):
            return c
    return -1
def crate_hash(txt):
    m = re.search(r'_RNvCs([A-Za-z0-9]+)_25rust_ziggy_indirect_calls', txt)
    return m.group(1) if m else ''
ana = crate_hash(json.dumps(reach))
cvg = crate_hash(json.dumps(cov))
print(g('fnptr_target_add'), g('method_pointer_call'), g('trait_object_vtable_call'),
      g('unreachable_fnptr_dead'), int(ana != '' and cvg != '' and ana != cvg))
PY
)
[ "$C_ADD" -gt 0 ] || die "coverage: fnptr_target_add should be covered by seed sel0 (got $C_ADD)"
[ "$C_MPC" -gt 0 ] || die "coverage: method_pointer_call should be covered by seed sel5 (got $C_MPC)"
assert_eq "$C_TOV" "0" "coverage: trait_object_vtable_call is reachable but not exercised (amber)"
assert_eq "$C_DEAD" "0" "coverage: unreachable_fnptr_dead is statically dead and must never be covered"
assert_eq "$DRIFT" "1" "v0 crate-disambiguator hash must differ between the ziggy analysis build and the -Cinstrument-coverage build (independent builds)"
echo "[PASS] stage 4: per-function coverage counters correct; v0 crate-hash drift confirmed (names are NOT byte-identical)"

# ── stage 5: reachability tally + recomputed function/line counters ─────────
PATH=/usr/bin:$PATH bash "$COV" report -d "$WORK/corpus" -e "$BIN @@" \
  -o "$WORK/covout_base" > "$TMP/report_base.log" 2>&1 \
  || die "baseline cov-analysis report failed: $(cat "$TMP/report_base.log")"

read -r T_REACH T_UNREACH T_ANOM EXCL FULL_FN FULL_COV FULL_LN RO_FN RO_COV RO_LN < <("$PY" - "$WORK/covout_base/summary.txt" "$WORK/covout/summary.txt" <<'PY'
import re, sys
base = open(sys.argv[1]).read()
reach = open(sys.argv[2]).read()
def num(pat, txt, dflt='NA'):
    m = re.search(pat, txt, re.M); return m.group(1) if m else dflt
t_reach = num(r'^\s*reachable functions\s*:\s*(\d+)', reach)
t_unreach = num(r'^\s*unreachable functions\s*:\s*(\d+)', reach)
t_anom = num(r'^\s*covered yet unreachable\s*:\s*(\d+)', reach, '0')
excl = num(r'excludes (\d+) statically-unreachable', reach)
b = re.search(r'^\S*main\.rs\S*\s+\d+\s+\d+\s+[\d.]+%\s+(\d+)\s+(\d+)\s+[\d.]+%\s+(\d+)\s+\d+\s+[\d.]+%', base, re.M)
full_fn, full_missed_fn, full_ln = b.group(1), b.group(2), b.group(3)
full_cov = str(int(full_fn) - int(full_missed_fn))
r = re.search(r'main\.rs\S*\s+[\d.]+% \((\d+)/(\d+)\)\s+[\d.]+% \((\d+)/(\d+)\)', reach)
ro_fn, ro_cov, ro_ln = r.group(2), r.group(1), r.group(4)
print(t_reach, t_unreach, t_anom, excl, full_fn, full_cov, full_ln, ro_fn, ro_cov, ro_ln)
PY
)
assert_eq "$T_UNREACH" "6" "summary.txt unreachable-function tally (the exported dead set present in coverage data)"
assert_eq "$T_ANOM" "0" "summary.txt covered-yet-unreachable tally (none: the ziggy entry has no load-time-only reachable code here)"
[ "$T_REACH" -ge 50 ] || die "summary.txt should report the reachable functions present in coverage data (got $T_REACH)"
assert_eq "$EXCL" "$T_UNREACH" "summary.txt 'excludes N statically-unreachable' note must equal the unreachable tally"
assert_eq "$((FULL_FN - RO_FN))" "$T_UNREACH" "reachable-only function denominator excludes exactly the unreachable functions ($FULL_FN full -> $RO_FN reachable-only)"
assert_eq "$((FULL_COV - RO_COV))" "$T_ANOM" "reachable-only covered-function numerator excludes exactly the covered-yet-unreachable functions ($FULL_COV covered -> $RO_COV; anomaly=$T_ANOM)"
[ "$((FULL_LN - RO_LN))" -ge "$T_UNREACH" ] || die "reachable-only line denominator ($RO_LN) must drop the $T_UNREACH unreachable functions' lines from the full main.rs total ($FULL_LN)"
grep -qi 'Reachable-only coverage' "$WORK/covout/summary.txt" || die "summary.txt should carry the reachable-only recomputed table"
echo "[PASS] stage 5: reachability tally (reachable=$T_REACH unreachable=6 anomaly=0); recomputed counters drop exactly the dead set (functions $FULL_FN->$RO_FN, lines $FULL_LN->$RO_LN)"

# ── stage 5b: HTML banner + clean per-line grey/amber tinting ───────────────
IDX="$WORK/covout/html/index.html"
grep -q 'reach-banner' "$IDX" || die "index.html should gain a reachability banner"
grep -q "$T_UNREACH unreachable" "$IDX" || die "index.html banner should report $T_UNREACH unreachable functions"
HFILE="$(find "$WORK/covout/html/coverage" -name 'main.rs.html' | head -1)"
[ -n "$HFILE" ] || die "no main.rs.html found under covout/html/coverage"
grep -q "class='reach-amber'" "$HFILE" || die "main.rs.html should tint reachable-but-unreached lines amber"
DEAD_LINE=$(grep -n 'pub extern "C" fn unreachable_fnptr_dead' "$WORK/src/main.rs" | head -1 | cut -d: -f1)
[ -n "$DEAD_LINE" ] || die "could not locate unreachable_fnptr_dead in the fixture source"
grep -q "reach-grey'><td class='line-number'><a name='L$DEAD_LINE'" "$HFILE" \
  || die "main.rs.html: unreachable_fnptr_dead (line $DEAD_LINE) should be tinted reach-grey"
echo "[PASS] stage 5b: index.html banner + main.rs.html tints unreachable_fnptr_dead grey and reachable-unreached amber"

# ── stage 6: prove the (file,line) fallback carries the drifting-v0 join ─────
"$PY" - "$WORK/reach.json" "$WORK/reach.nulled.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for fn in d.get('reachable', []) + d.get('unreachable_defined', []):
    fn['file'] = None; fn['line'] = None
json.dump(d, open(sys.argv[2], 'w'))
PY
PATH=/usr/bin:$PATH bash "$COV" report -d "$WORK/corpus" -e "$BIN @@" \
  --reachability "$WORK/reach.nulled.json" -o "$WORK/covout_nulled" > "$TMP/report_nulled.log" 2>&1 \
  || die "cov-analysis report (file/line nulled) failed: $(cat "$TMP/report_nulled.log")"
read -r NULL_REACH NULL_UNREACH < <("$PY" - "$WORK/covout_nulled/summary.txt" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
def num(pat, dflt='NA'):
    m = re.search(pat, t, re.M); return m.group(1) if m else dflt
print(num(r'^\s*reachable functions\s*:\s*(\d+)'), num(r'^\s*unreachable functions\s*:\s*(\d+)'))
PY
)
[ "$NULL_REACH" -lt "$T_REACH" ] || die "nulling file/line should shrink the crate-function reachable join ($T_REACH -> $NULL_REACH), since v0 crate hashes drift"
[ "$NULL_REACH" -le 10 ] || die "with file/line stripped, only the (few) exact-name matches should remain reachable, got $NULL_REACH"
assert_eq "$NULL_UNREACH" "6" "the #[no_mangle] dead set still classifies unreachable by exact name even with file/line stripped"
echo "[PASS] stage 6: (file,line) fallback carries the drifting-v0 crate join ($T_REACH reachable -> $NULL_REACH when stripped); #[no_mangle] names join regardless (unreachable stays 6)"

echo "[PASS] test_reachability_ziggy_e2e"
