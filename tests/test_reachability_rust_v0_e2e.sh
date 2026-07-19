#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
COV="$(pwd)/cov-analysis"

FIXTURE="${FUZZ_REACH_FIXTURE:-/prg/fuzz-reachability/fixtures/rust_generic}"
REACH_CLI="${FUZZ_REACH_CLI:-/prg/fuzz-reachability/driver/.venv/bin/reachability}"
ANALYZER="${FUZZ_REACH_ANALYZER:-/prg/fuzz-reachability/analyzer/build/reachability-analyzer}"
REACH_EXTRA_PATH="${FUZZ_REACH_EXTRA_PATH:-$(go env GOPATH 2>/dev/null)/bin}"

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not available"; exit 0; }
[ -d "$FIXTURE" ]   || { echo "[SKIP] fixtures/rust_generic not found (fuzz-reachability checkout missing)"; exit 0; }
[ -x "$REACH_CLI" ] || { echo "[SKIP] reachability driver venv not found: $REACH_CLI"; exit 0; }
[ -x "$ANALYZER" ]  || { echo "[SKIP] reachability-analyzer binary not built: $ANALYZER"; exit 0; }
command -v cargo >/dev/null 2>&1 || { echo "[SKIP] cargo not available"; exit 0; }
command -v rustc >/dev/null 2>&1 || { echo "[SKIP] rustc not available"; exit 0; }

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)
TOOLCHAIN="$(select_rust_llvm_toolchain || true)"
if test -z "$TOOLCHAIN"; then
  RUST_MAJOR="$(rustc_llvm_major || true)"
  echo "[SKIP] rustc LLVM ${RUST_MAJOR:-unknown} has no complete matching clang/llvm-cov/llvm-profdata set"
  exit 0
fi
IFS=$'\t' read -r RUST_MAJOR CLANG COVTOOL PROFDATA <<< "$TOOLCHAIN"
TOOLBIN="$TMP/llvm-tools"
mkdir -p "$TOOLBIN"
ln -s "$COVTOOL" "$TOOLBIN/llvm-cov"; ln -s "$COVTOOL" "$TOOLBIN/llvm-cov-$RUST_MAJOR"
ln -s "$PROFDATA" "$TOOLBIN/llvm-profdata"; ln -s "$PROFDATA" "$TOOLBIN/llvm-profdata-$RUST_MAJOR"
export PATH="$TOOLBIN:$PATH" CC="$CLANG"
WORK="$TMP/work"
cp -r "$FIXTURE" "$WORK"

python3 - "$WORK/src/lib.rs" << 'PYEOF'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
marker = '#[no_mangle]\npub extern "C" fn LLVMFuzzerTestOneInput'
dead = ('#[inline(never)]\n#[no_mangle]\n'
        'pub extern "C" fn dead_fn(x: i32) -> i32 {\n    x * 2\n}\n\n')
if marker not in src:
    sys.exit("fixture layout changed: LLVMFuzzerTestOneInput marker not found")
open(path, 'w', encoding='utf-8').write(src.replace(marker, dead + marker, 1))
PYEOF
DEAD_LINE=$(grep -n '^pub extern "C" fn dead_fn' "$WORK/src/lib.rs" | head -n1 | cut -d: -f1)
[ -n "$DEAD_LINE" ] || die "could not locate injected dead_fn line"

if ! REACHABILITY_ANALYZER="$ANALYZER" PATH="$REACH_EXTRA_PATH:$PATH" \
  "$REACH_CLI" run --lang rust --project "$WORK" --entry LLVMFuzzerTestOneInput \
  --mangling v0 --out "$WORK/reach.json" > "$TMP/reach_run.log" 2>&1; then
  if grep -qiE 'bundled LLVM|bitcode cannot be read|LLVM_MAJOR' "$TMP/reach_run.log"; then
    echo "[SKIP] reachability analyzer/rustc LLVM toolchain mismatch: $(tail -n1 "$TMP/reach_run.log")"
    exit 0
  fi
  die "reachability run failed: $(cat "$TMP/reach_run.log")"
fi
[ -f "$WORK/reach.json" ]         || die "reach.json was not produced"
[ -f "$WORK/reached.txt" ]        || die "reached.txt was not produced"
[ -f "$WORK/not_reached.txt" ]    || die "not_reached.txt was not produced"

read -r MANGLING N_DEFINED N_REACHABLE N_UNREACHABLE < <(python3 -c "
import json
d = json.load(open('$WORK/reach.json'))
s = d['summary']
print(d['mangling'], s['defined'], s['reachable'], s['unreachable'])
")
assert_eq "$MANGLING" "v0" "reach.json top-level mangling field"
assert_eq "$N_DEFINED" "6" "reach.json summary.defined"
assert_eq "$N_REACHABLE" "5" "reach.json summary.reachable"
assert_eq "$N_UNREACHABLE" "1" "reach.json summary.unreachable"
grep -q 'fun:LLVMFuzzerTestOneInput' "$WORK/reached.txt"     || die "reached.txt missing LLVMFuzzerTestOneInput"
grep -q 'fun:dead_fn' "$WORK/not_reached.txt"                || die "not_reached.txt missing dead_fn"

REACH_MANGLED_WORK="$(python3 -c "
import json
d = json.load(open('$WORK/reach.json'))
print(next(f['mangled'] for f in d['reachable'] if 'work' in f['mangled']))
")"
case "$REACH_MANGLED_WORK" in
  _R*) : ;;
  *) die "expected a v0-mangled ('_R'-prefixed) 'work' symbol in reach.json, got: $REACH_MANGLED_WORK" ;;
esac
echo "[PASS] stage 1: static reachability analysis built with --mangling v0 (defined=6 reachable=5 unreachable=1, mangling=v0, work=$REACH_MANGLED_WORK)"

( cd "$WORK" && FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1 \
    RUSTFLAGS="-Cinstrument-coverage" cargo build > "$TMP/cargo_build.log" 2>&1 ) \
  || die "coverage cargo build failed: $(cat "$TMP/cargo_build.log")"
[ -f "$WORK/target/debug/librust_generic.a" ] || die "librust_generic.a was not built"
echo "[PASS] stage 2: coverage-instrumented build compiled (-Cinstrument-coverage implies v0, matching the analysis build's --mangling v0)"

bash "$COV" driver -o "$WORK/coverage_driver.c" >/dev/null
"$CLANG" -fprofile-instr-generate -fcoverage-mapping -c "$WORK/coverage_driver.c" -o "$WORK/coverage_driver.o" \
  || die "compiling coverage_driver.c failed"
"$CLANG" -fprofile-instr-generate "$WORK/coverage_driver.o" \
  -L"$WORK/target/debug" -lrust_generic -o "$WORK/cov" -lpthread -ldl -lm \
  || die "linking the cov replay binary failed"
LLVM_PROFILE_FILE="$TMP/printsignature.profraw" "$WORK/cov" --printsignature \
  | grep -q '###SIGNATURE_LLVMFUZZERTESTONEINPUT_COVERAGE###' \
  || die "cov binary does not carry the cov-analysis driver signature"
echo "[PASS] stage 3: coverage_driver.c linked against the Rust staticlib"

mkdir -p "$WORK/corpus"
printf '\x05' > "$WORK/corpus/seed1"
bash "$COV" report -d "$WORK/corpus" -e "$WORK/cov @@" \
  --reachability "$WORK/reach.json" -o "$WORK/covout" > "$TMP/report.log" 2>&1 \
  || die "cov-analysis report failed: $(cat "$TMP/report.log")"
[ -f "$WORK/covout/coverage.json" ] || die "covout/coverage.json was not produced"

COV_NAME_WORK="$(python3 -c "
import json
d = json.load(open('$WORK/covout/coverage.json'))
names = [fn['name'] for obj in d['data'] for fn in obj['functions'] if 'work' in fn['name']]
print(names[0] if names else '')
")"
[ -n "$COV_NAME_WORK" ] || die "no 'work' function found in covout/coverage.json"
[ "$COV_NAME_WORK" = "$REACH_MANGLED_WORK" ] \
  || die "v0 mangling should make coverage and reachability 'work' names byte-identical, got '$COV_NAME_WORK' vs '$REACH_MANGLED_WORK'"
echo "[PASS] stage 4: cov-analysis report ran real llvm-cov (v0 names byte-identical on both sides: $REACH_MANGLED_WORK)"

assert_v0_report() {
  local OUTDIR="$1" LABEL="$2"
  local HFILE
  HFILE="$(find "$OUTDIR/html/coverage" -name 'lib.rs.html')"
  [ -n "$HFILE" ] || die "$LABEL: no lib.rs.html found under $OUTDIR/html/coverage"
  for ln in "$DEAD_LINE" "$((DEAD_LINE + 1))" "$((DEAD_LINE + 2))"; do
    grep -q "reach-grey'><td class='line-number'><a name='L$ln'" "$HFILE" \
      || die "$LABEL: html: dead_fn line $ln should get class reach-grey"
  done
  local N_REACH_CLASSES
  N_REACH_CLASSES="$(grep -o "class='reach-[a-z-]*'" "$HFILE" | wc -l)"
  assert_eq "$N_REACH_CLASSES" "3" "$LABEL: html: only the 3 dead_fn lines should carry a reach-* class (work/LLVMFuzzerTestOneInput must classify covered, not unknown)"
  grep -qi 'reachab' "$OUTDIR/html/index.html" || die "$LABEL: index.html should gain a reachability banner"
  grep -q ': 3 reachable' "$OUTDIR/html/index.html" \
    || die "$LABEL: index.html banner should report 3 reachable functions"
  grep -q '1 unreachable' "$OUTDIR/html/index.html" \
    || die "$LABEL: index.html banner should report 1 unreachable function"
  grep -Eq '^ *reachable functions +: 3$' "$OUTDIR/summary.txt" \
    || die "$LABEL: summary.txt should count 3 reachable functions"
  grep -Eq 'unreachable functions +: 1' "$OUTDIR/summary.txt" \
    || die "$LABEL: summary.txt should count 1 unreachable function"
}

assert_v0_report "$WORK/covout" "same-scheme run"
echo "[PASS] stage 5: html/summary classify work/LLVMFuzzerTestOneInput as reachable-covered (not unknown) and dead_fn as unreachable"

python3 -c "
import json
d = json.load(open('$WORK/reach.json'))
for fn in d.get('reachable', []):
    fn['file'] = None
    fn['line'] = None
for fn in d.get('unreachable_defined', []):
    fn['file'] = None
    fn['line'] = None
json.dump(d, open('$WORK/reach.nulled.json', 'w'))
"
python3 -c "
import json
d = json.load(open('$WORK/reach.nulled.json'))
assert all(fn['file'] is None and fn['line'] is None for fn in d['reachable'] + d['unreachable_defined'])
" || die "reach.nulled.json setup did not strip file/line as expected"

bash "$COV" report -d "$WORK/corpus" -e "$WORK/cov @@" \
  --reachability "$WORK/reach.nulled.json" -o "$WORK/covout_nameonly" > "$TMP/report_nameonly.log" 2>&1 \
  || die "cov-analysis report (file/line stripped from reachability.json) failed: $(cat "$TMP/report_nameonly.log")"
assert_v0_report "$WORK/covout_nameonly" "file/line-stripped run"
echo "[PASS] stage 6: with file/line stripped from reach.json, the (file,line) fallback structurally cannot fire, yet classification is unchanged -- the join is by exact v0 NAME/key, not the fallback"

echo "[PASS] test_reachability_rust_v0_e2e"
