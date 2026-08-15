#!/usr/bin/env bash
# Regression test: an input that hits its replay deadline must be named in the
# report.
#
# Field report: a non-terminating corpus entry is a finding in its own right.
# The user only found theirs by inspecting worker ages with ps; the tool knew
# which input it had killed and said nothing.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
source tests/lib.sh
source ./cov-analysis
set +e   # sourcing cov-analysis enables `set -e`; we capture exit codes by hand

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
mkdir -p "$TOOLS" "$TMP/out/queue"
printf a > "$TMP/out/queue/id:000000,time:0,src:000"
printf hang > "$TMP/out/queue/id:000001,time:0,src:000"
printf c > "$TMP/out/queue/id:000002,time:0,src:000"
HANG_INPUT="$TMP/out/queue/id:000001,time:0,src:000"

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
    else
      printf '/tmp/source.c:\n    1|      1| int f(void);\n' > "$out/coverage/source.txt"
    fi
    ;;
  report) printf 'summary\n' ;;
  export) printf '{"data":[{"files":[],"functions":[]}]}\n' ;;
esac
EOF
cat > "$TMP/target" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
for f in "$@"; do
  test -f "$f" || continue
  test "$(cat "$f")" = hang && { sleep 300 & wait $!; }
done
exit 0
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export CC=/bin/true

# ── loop mode: the shell names the input it killed ────────────────────────────
rm -rf "$TMP/rep"
out=$(PATH="$TOOLS:/usr/bin:/bin" timeout 120 bash "$ROOT/cov-analysis" report \
  -d "$TMP/out" -e "$TMP/target @@ /dev/null" -o "$TMP/rep" --queue-timeout 2 2>&1)
assert_eq "$?" "0" "the run must publish even when an input hit the deadline: $out"
test -s "$TMP/rep/slow_inputs.txt" || die "no slow input inventory was published: $out"
grep -qxF "$HANG_INPUT" "$TMP/rep/slow_inputs.txt" \
  || die "the inventory does not name the input that hung: $(cat "$TMP/rep/slow_inputs.txt")"
assert_eq "$(grep -cv '^#' "$TMP/rep/slow_inputs.txt")" "1" "only the input that hung belongs in the inventory"
grep -q '^# inputs that exceeded their replay deadline (queue: 2s' "$TMP/rep/slow_inputs.txt" \
  || die "the inventory does not record the deadline that was applied"
printf '%s\n' "$out" | grep -q '1 input(s) exceeded their replay deadline' \
  || die "the run did not point at the inventory: $out"
echo "[PASS] loop mode names the input it killed"

# ── a clean corpus publishes no inventory ─────────────────────────────────────
rm -rf "$TMP/rep" "$TMP/out/queue/id:000001,time:0,src:000"
out=$(PATH="$TOOLS:/usr/bin:/bin" timeout 120 bash "$ROOT/cov-analysis" report \
  -d "$TMP/out" -e "$TMP/target @@ /dev/null" -o "$TMP/rep" --queue-timeout 2 2>&1)
assert_eq "$?" "0" "a clean corpus must still publish: $out"
test -e "$TMP/rep/slow_inputs.txt" \
  && die "a run without slow inputs must not publish an inventory"
echo "[PASS] no inventory without slow inputs"

# ── batch mode: the driver names the input, inside a shared process ───────────
CLANG="$(detect_clang || true)"
if test -z "$CLANG"; then
  echo "[SKIP] batch mode inventory (clang unavailable)"
  echo "[PASS] test_slow_input_inventory"
  exit 0
fi
DRIVER="$TMP/coverage_driver.c"
bash "$ROOT/cov-analysis" driver -o "$DRIVER" >/dev/null
cat > "$TMP/harness.c" <<'EOF'
#include <stddef.h>
#include <unistd.h>
static volatile int sink;
int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size) {
  if (size > 0 && data[0] == 'h') { for (;;) sleep(1); }
  sink += (int)size;
  return 0;
}
EOF
"$CLANG" -fprofile-instr-generate -fcoverage-mapping "$DRIVER" "$TMP/harness.c" \
  -o "$TMP/cov" || die "driver compilation failed"

printf hang > "$HANG_INPUT"
rm -rf "$TMP/rep"
out=$(PATH="$TOOLS:/usr/bin:/bin" timeout 120 bash "$ROOT/cov-analysis" report \
  -d "$TMP/out" -e "$TMP/cov @@" --binary "$TMP/cov" -o "$TMP/rep" \
  --queue-timeout 2 2>&1)
assert_eq "$?" "0" "batch replay with a hanging input must publish: $out"
grep -qxF "$HANG_INPUT" "$TMP/rep/slow_inputs.txt" \
  || die "batch mode did not name the input that hung: $(cat "$TMP/rep/slow_inputs.txt" 2>/dev/null)"
# The rest of the batch must survive: the driver jumps past the hung input
# rather than the whole batch being killed and losing its profile. So the batch
# reports success for all three inputs and the inventory carries the one that
# was skipped.
printf '%s\n' "$out" | grep -q 'Queue replay *: 3 ok, 0 failed, 0 timed out' \
  || die "the batch must complete around the input that hung: $out"
test -s "$TMP/rep/coverage.profdata" || die "the batch lost its profile"
echo "[PASS] batch mode names the input it killed"

echo "[PASS] test_slow_input_inventory"
