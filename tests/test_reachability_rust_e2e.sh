#!/usr/bin/env bash
# tests/test_reachability_rust_e2e.sh — keystone round-trip: fuzz-reachability's
# static analysis of a real Rust staticlib, cross-referenced against a real
# `-Cinstrument-coverage` build replayed through llvm-cov, via cov-analysis's
# own `report --reachability`. No synthetic JSON/HTML fixtures here — every
# input is produced by the real toolchains, so the join between the two tools'
# independently-mangled symbol names cannot rely on a lucky exact match.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
COV="$(pwd)/cov-analysis"

FIXTURE="${FUZZ_REACH_FIXTURE:-/prg/fuzz-reachability/fixtures/rust_generic}"
REACH_CLI="${FUZZ_REACH_CLI:-/prg/fuzz-reachability/driver/.venv/bin/reachability}"
ANALYZER="${FUZZ_REACH_ANALYZER:-/prg/fuzz-reachability/analyzer/build/reachability-analyzer}"

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

# ── inject a genuinely-dead function: the checked-in fixture is fully
# reachable (see expected.json), so add one uncalled #[no_mangle] function to
# this disposable copy to exercise the "unreachable" classification too ──────
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

# ── stage 1: static reachability analysis of the (unbuilt) staticlib ────────
if ! REACHABILITY_ANALYZER="$ANALYZER" \
  "$REACH_CLI" run --lang rust --project "$WORK" --entry LLVMFuzzerTestOneInput \
  --out "$WORK/reach.json" > "$TMP/reach_run.log" 2>&1; then
  if grep -qiE 'bundled LLVM|bitcode cannot be read|LLVM_MAJOR' "$TMP/reach_run.log"; then
    echo "[SKIP] reachability analyzer/rustc LLVM toolchain mismatch: $(tail -n1 "$TMP/reach_run.log")"
    exit 0
  fi
  die "reachability run failed: $(cat "$TMP/reach_run.log")"
fi
[ -f "$WORK/reach.json" ]         || die "reach.json was not produced"
[ -f "$WORK/reached.txt" ]        || die "reached.txt was not produced"
[ -f "$WORK/not_reached.txt" ]    || die "not_reached.txt was not produced"

read -r N_DEFINED N_REACHABLE N_UNREACHABLE < <(python3 -c "
import json
d = json.load(open('$WORK/reach.json'))
s = d['summary']
print(s['defined'], s['reachable'], s['unreachable'])
")
assert_eq "$N_DEFINED" "6" "reach.json summary.defined"
assert_eq "$N_REACHABLE" "5" "reach.json summary.reachable"
assert_eq "$N_UNREACHABLE" "1" "reach.json summary.unreachable"
grep -q 'fun:LLVMFuzzerTestOneInput' "$WORK/reached.txt"     || die "reached.txt missing LLVMFuzzerTestOneInput"
grep -q 'fun:dead_fn' "$WORK/not_reached.txt"                || die "not_reached.txt missing dead_fn"
echo "[PASS] stage 1: static reachability analysis (defined=6 reachable=5 unreachable=1)"

# ── stage 2: real llvm source-based coverage build of the SAME crate ────────
# `-C instrument-coverage` implies `-C symbol-mangling-version=v0`, so the
# `work::<u32|u64>` monomorphizations get mangled names that share no
# substring with the legacy (`17h<hash>E`-suffixed) names the reachability
# analysis above just recorded -- the join below cannot be an accidental
# exact-name match.
( cd "$WORK" && FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1 \
    RUSTFLAGS="-Cinstrument-coverage" cargo build > "$TMP/cargo_build.log" 2>&1 ) \
  || die "coverage cargo build failed: $(cat "$TMP/cargo_build.log")"
[ -f "$WORK/target/debug/librust_generic.a" ] || die "librust_generic.a was not built"

REACH_MANGLED_WORK="$(python3 -c "
import json
d = json.load(open('$WORK/reach.json'))
print(next(f['mangled'] for f in d['reachable'] if 'work' in f['mangled']))
")"
case "$REACH_MANGLED_WORK" in
  _ZN*17h*E) : ;;
  *) die "expected a legacy-mangled 'work' symbol in reach.json, got: $REACH_MANGLED_WORK" ;;
esac
echo "[PASS] stage 2: coverage-instrumented build compiled (legacy-mangled reach.json vs v0-forced coverage binary)"

# ── stage 3: emit + link the cov-analysis replay driver against the staticlib
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

# ── stage 4: replay one input and let cov-analysis drive llvm-cov + annotate
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
[ "$COV_NAME_WORK" != "$REACH_MANGLED_WORK" ] \
  || die "test setup bug: coverage and reachability 'work' names should differ (v0 vs legacy mangling)"
echo "[PASS] stage 4: cov-analysis report ran real llvm-cov (mismatched names confirmed: $REACH_MANGLED_WORK vs $COV_NAME_WORK)"

# ── stage 5: HTML/summary assertions -- the mismatched-mangling generics
# still classify covered/reachable-unreached (never unknown); the injected
# dead function classifies unreachable ────────────────────────────────────
HFILE="$(find "$WORK/covout/html/coverage" -name 'lib.rs.html')"
[ -n "$HFILE" ] || die "no lib.rs.html found under covout/html/coverage"
for ln in "$DEAD_LINE" "$((DEAD_LINE + 1))" "$((DEAD_LINE + 2))"; do
  grep -q "reach-grey'><td class='line-number'><a name='L$ln'" "$HFILE" \
    || die "html: dead_fn line $ln should get class reach-grey"
done
echo "[PASS] stage 5: html tints the injected dead_fn reach-grey (unreachable)"

N_REACH_CLASSES="$(grep -o "class='reach-[a-z-]*'" "$HFILE" | wc -l)"
assert_eq "$N_REACH_CLASSES" "3" "html: only the 3 dead_fn lines should carry a reach-* class (work/LLVMFuzzerTestOneInput must stay untouched, i.e. classified covered, not unknown)"
echo "[PASS] stage 5: reachable work/LLVMFuzzerTestOneInput lines are untouched (covered, not unknown/unreachable)"

grep -qi 'reachab' "$WORK/covout/html/index.html" || die "index.html should gain a reachability banner"
grep -q ': 3 reachable' "$WORK/covout/html/index.html" \
  || die "index.html banner should report 3 reachable functions (present in coverage: entry + 2 work instances)"
grep -q '1 unreachable' "$WORK/covout/html/index.html" \
  || die "index.html banner should report 1 unreachable function (dead_fn)"
echo "[PASS] stage 5: index.html banner reports the correct reachable/unreachable tally"

grep -Eq '^ *reachable functions +: 3$' "$WORK/covout/summary.txt" \
  || die "summary.txt should count 3 reachable functions"
grep -Eq 'unreachable functions +: 1' "$WORK/covout/summary.txt" \
  || die "summary.txt should count 1 unreachable function"
grep -qi 'Reachable-only coverage' "$WORK/covout/summary.txt" \
  || die "summary.txt should carry the reachable-only recomputed table"
grep -q 'excludes 1 statically-unreachable function' "$WORK/covout/summary.txt" \
  || die "summary.txt should note dead_fn was excluded from the reachable-only numbers"
echo "[PASS] stage 5: summary.txt reachability tally + reachable-only table"

echo "[PASS] test_reachability_rust_e2e"
