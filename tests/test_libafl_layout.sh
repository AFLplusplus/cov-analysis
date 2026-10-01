#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"

mkfixture_libafl "$TMP/libafl"
for f in "$TMP/libafl/corpus"/* "$TMP/libafl/corpus"/.??* \
         "$TMP/libafl/crashes"/* "$TMP/libafl/crashes"/.??*; do
  printf '%s' "${f##*/}" > "$f"
done

cat > "$TMP/target" <<'EOF'
#!/bin/bash
cat -- "$1" >> "$TRACE_FILE"
printf '\n' >> "$TRACE_FILE"
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
cat > "$TOOLS/llvm-profdata" <<'EOF'
#!/bin/bash
out=""
while test $# -gt 0; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf merged > "$out"
EOF
printf '#!/bin/bash\nexit 0\n' > "$TOOLS/llvm-cov"
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export CC=/bin/true TRACE_FILE="$TMP/trace"

replay() {
  local dir="$1"; shift
  : > "$TRACE_FILE"
  rm -rf "$TMP/rep"
  PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report -d "$dir" \
    -e "$TMP/target @@" -o "$TMP/rep" --replay-only "$@" > "$TMP/log" 2>&1
}

replay "$TMP/libafl" || die "LibAFL replay failed: $(cat "$TMP/log")"
grep -q 'Fuzzer layout   : LibAFL' "$TMP/log" \
  || die "a LibAFL output directory must be detected as LibAFL: $(cat "$TMP/log")"
grep -q 'Replaying 2 queue files' "$TMP/log" \
  || die "both corpus entries must be replayed: $(cat "$TMP/log")"
grep -q 'Replaying 1 crash/timeout files' "$TMP/log" \
  || die "the crashes/ entry must be replayed: $(cat "$TMP/log")"
assert_eq "$(LC_ALL=C sort "$TRACE_FILE" | tr '\n' ' ')" \
  "3f2a9c1d7e8b4a60 9b1e44d0c2a7f315 c0ffee1234567890 " "replayed LibAFL inputs"
echo "[PASS] a LibAFL output directory replays its corpus and crashes"

replay "$TMP/libafl/corpus" || die "corpus replay failed: $(cat "$TMP/log")"
assert_eq "$(LC_ALL=C sort "$TRACE_FILE" | tr '\n' ' ')" \
  "3f2a9c1d7e8b4a60 9b1e44d0c2a7f315 " "replayed corpus inputs"
echo "[PASS] hidden LibAFL metadata files are not replayed"

replay "$TMP/libafl" --layout libafl || die "--layout libafl failed: $(cat "$TMP/log")"
replay "$TMP/libafl" --layout bogus && die "--layout bogus must be refused"
grep -q "'afl', 'libafl' or 'flat'" "$TMP/log" \
  || die "the --layout refusal must name libafl: $(cat "$TMP/log")"
echo "[PASS] --layout libafl is accepted"

replay "$TMP/libafl" --layout afl && die "a run that selects no input must fail"
grep -q 'No input files found' "$TMP/log" \
  || die "a run that selects no input must say so: $(cat "$TMP/log")"
grep -q 'No .profraw files generated' "$TMP/log" \
  && die "a run that selects no input must not blame the instrumentation"
echo "[PASS] a run that selects no input says so"

echo "[PASS] test_libafl_layout"
