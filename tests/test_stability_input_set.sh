#!/usr/bin/env bash
# Regression test: every analyzed stability pass must measure the SAME inputs.
#
# An input killed at the -T deadline never runs its atexit profile write, so it
# contributes nothing to that pass. Under -t contention a borderline input
# crosses the deadline in some passes and not others, and every line only it
# covers flips between 0 and N — reported as instability that does not exist.
#
# The stub llvm-profdata records one line per merged .profraw, and the stub
# llvm-cov reports that count as the hit count of a single line: the reported
# hit count is therefore exactly the number of inputs that contributed to the
# pass, which is the quantity that must not vary.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/corpus"
printf a > "$TMP/corpus/a"
printf b > "$TMP/corpus/b"
printf c > "$TMP/corpus/c"

cat > "$BIN/llvm-profdata" <<'EOF'
#!/bin/bash
out=""; manifest=""
while test $# -gt 0; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --input-files=*) manifest="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
: > "$out"
test -n "$manifest" && cat "$manifest" >> "$out"
test -s "$out"
EOF
cat > "$BIN/llvm-cov" <<'EOF'
#!/bin/bash
test "$1" = export || exit 0
prof=""
for arg in "$@"; do case "$arg" in -instr-profile=*) prof="${arg#*=}";; esac; done
n=$(grep -c . "$prof" 2>/dev/null || printf 0)
printf 'SF:/src/x.c\nDA:1,%d\nend_of_record\n' "$n"
EOF

# One input crosses the deadline in pass 2 only — the flaky-under-load case.
cat > "$TMP/target_flaky" <<'EOF'
#!/bin/bash
case "$LLVM_PROFILE_FILE" in
  */run_2/*) case "$1" in *c) sleep 5 ;; esac ;;
esac
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF

# Different victims in different passes: nothing survives every pass.
cat > "$TMP/target_all" <<'EOF'
#!/bin/bash
case "$LLVM_PROFILE_FILE" in
  */run_2/*) case "$1" in *a|*b) sleep 5 ;; esac ;;
  */run_3/*) case "$1" in *c) sleep 5 ;; esac ;;
esac
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
chmod +x "$BIN/llvm-profdata" "$BIN/llvm-cov" "$TMP/target_flaky" "$TMP/target_all"
export CC=/bin/true

out=$(PATH="$BIN:/usr/bin:/bin" bash ./cov-analysis stability -d "$TMP/corpus" \
  -e "$TMP/target_flaky @@" -n 4 -T 1 2>&1)
rc=$?
assert_eq "$rc" "0" "stability run failed: $out"
printf '%s\n' "$out" | grep -q 'perfectly stable' \
  || die "an input missing from one pass was reported as instability: $out"
printf '%s\n' "$out" | grep -q 'Excluded 1 of 3 inputs' \
  || die "the excluded input was not reported: $out"
echo "[PASS] an input lost to the deadline is excluded from every pass"

out=$(PATH="$BIN:/usr/bin:/bin" bash ./cov-analysis stability -d "$TMP/corpus" \
  -e "$TMP/target_all @@" -n 3 -T 1 2>&1)
rc=$?
test "$rc" -ne 0 || die "an empty surviving input set must not report a result: $out"
printf '%s\n' "$out" | grep -qi 'no input produced coverage' \
  || die "the empty input set was not explained: $out"
echo "[PASS] an empty surviving input set fails with a clear message"

echo "[PASS] test_stability_input_set"
