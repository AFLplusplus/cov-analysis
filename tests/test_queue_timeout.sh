#!/usr/bin/env bash
# Regression test: queue replay must have a deadline, and that deadline must be
# derived from the campaign.
#
# Field report: a 12k-entry corpus held one input that does not terminate under
# coverage instrumentation. Six workers sat on it for 110 minutes while the run
# looked merely slow. -T bounded crash replay only; queue replay had no
# deadline at all, in any of its three modes.
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

# ── the derivation ────────────────────────────────────────────────────────────
mk_stats() { mkdir -p "$(dirname "$1")" && printf 'slowest_exec_ms   : %s\nexec_timeout      : %s\n' "$2" "$3" > "$1"; }

D="$TMP/derive"
mk_stats "$D/fuzzer_stats" 8 1000
read -r secs ms instances < <(derive_queue_timeout "$D" afl)
assert_eq "$secs" "5" "8ms must round up to 1s and scale to the 5s minimum"
assert_eq "$ms" "8" "the derivation must report the ms it used"
assert_eq "$instances" "1" "one fuzzer_stats is one instance"

mk_stats "$D/fuzzer_stats" 4500 9000
read -r secs ms instances < <(derive_queue_timeout "$D" afl)
assert_eq "$secs" "25" "4500ms must round up to 5s and scale by 5"

# Parallel instances: the slowest of them all sets the deadline.
rm -rf "$D"; mkdir -p "$D"
mk_stats "$D/main/fuzzer_stats" 8 1000
mk_stats "$D/secondary1/fuzzer_stats" 2200 1000
mk_stats "$D/secondary2/fuzzer_stats" 40 1000
read -r secs ms instances < <(derive_queue_timeout "$D" afl)
assert_eq "$secs" "15" "the slowest instance must set the deadline"
assert_eq "$ms" "2200" "the maximum slowest_exec_ms must win"
assert_eq "$instances" "3" "every instance must be counted"

# No slowest_exec_ms (an old AFL, or a run that never wrote one): exec_timeout.
rm -rf "$D"; mkdir -p "$D"
printf 'exec_timeout      : 3000\n' > "$D/fuzzer_stats"
read -r secs ms instances < <(derive_queue_timeout "$D" afl)
assert_eq "$secs" "15" "exec_timeout must stand in for a missing slowest_exec_ms"

# An empty stats file parses to nothing; a flat corpus has none at all.
rm -rf "$D"; mkdir -p "$D"
: > "$D/fuzzer_stats"
read -r secs ms instances < <(derive_queue_timeout "$D" afl)
assert_eq "$secs" "60" "an unusable fuzzer_stats must fall back to the default"
assert_eq "$ms" "0" "an unusable fuzzer_stats reports no ms"
read -r secs ms instances < <(derive_queue_timeout "$D" flat)
assert_eq "$secs" "60" "a flat layout has no fuzzer_stats to derive from"
echo "[PASS] the deadline is derived from slowest_exec_ms"

# ── enforcement ───────────────────────────────────────────────────────────────
# The target hangs on one input and writes its profile on TERM, the way the
# coverage driver does — so a TERM-first kill keeps the coverage it collected.
cat > "$TMP/target" <<'EOF'
#!/bin/bash
write_profile() {
  local p="${LLVM_PROFILE_FILE//%p/$$}"
  mkdir -p "$(dirname "$p")"
  printf profile > "$p"
}
trap 'write_profile; exit 143' TERM
hang_now() { sleep 300 & wait $!; }
if test $# -eq 0; then
  # stdin mode
  test "$(cat)" = hang && hang_now
else
  for f in "$@"; do
    test -f "$f" || continue
    test "$(cat "$f")" = hang && hang_now
  done
fi
write_profile
exit 0
EOF
cat > "$TOOLS/llvm-profdata" <<'EOF'
#!/bin/bash
out=""; manifest=""
while test $# -gt 0; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --input-files=*) manifest="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
if test -n "$manifest" && test -n "${MERGE_COUNT_FILE:-}"; then
  wc -l < "$manifest" > "$MERGE_COUNT_FILE"
fi
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
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
# CC without a version keeps find_tool from preferring a real llvm-profdata-NN
# over the stub.
export CC=/bin/true MERGE_COUNT_FILE="$TMP/merged"

run_report() {
  rm -rf "$TMP/rep" "$TMP/merged"
  PATH="$TOOLS:/usr/bin:/bin" timeout 120 \
    bash "$ROOT/cov-analysis" report -d "$TMP/out" -o "$TMP/rep" -t 3 "$@" 2>&1
}

# Batch mode (trailing @@ against a driver) cannot be tested with a stub
# target — the batch path needs a real driver binary. These runs take the loop
# and stdin paths, which is where the literal 0 deadline used to be.
start=$(date +%s)
out=$(run_report -e "$TMP/target @@ /dev/null" --queue-timeout 3)
rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$rc" "0" "a corpus with a hanging input must still finish: $out"
test "$elapsed" -lt 100 || die "the deadline did not bound the run (${elapsed}s)"
printf '%s\n' "$out" | grep -q 'Queue replay *: 2 ok, 0 failed, 1 timed out' \
  || die "the killed input was not accounted for: $out"
echo "[PASS] a hanging queue input no longer pins a worker"

# TERM before KILL: the target's own profile write must survive the deadline,
# so all three inputs contribute a profile to the merge.
assert_eq "$(cat "$TMP/merged")" "3" "the deadline must kill with TERM first, so profiles survive"
echo "[PASS] the deadline kills with TERM before KILL"

# The stdin path took the same literal 0.
out=$(run_report -e "$TMP/target" --queue-timeout 3)
printf '%s\n' "$out" | grep -q 'Queue replay *: 2 ok, 0 failed, 1 timed out' \
  || die "stdin replay was not bounded: $out"
echo "[PASS] stdin replay is bounded too"

# The derived default reaches the run, and is reported.
printf 'slowest_exec_ms   : 900\n' > "$TMP/out/fuzzer_stats"
out=$(run_report -e "$TMP/target @@ /dev/null")
printf '%s\n' "$out" | grep -q 'Queue timeout *: 5s (slowest_exec_ms=900 over 1 instance(s), x5, min 5s)' \
  || die "the derived deadline was not reported: $out"
rm -f "$TMP/out/fuzzer_stats"

out=$(run_report -e "$TMP/target @@ /dev/null")
printf '%s\n' "$out" | grep -q 'Queue timeout *: 60s (no AFL++ fuzzer_stats' \
  || die "the fallback deadline was not reported: $out"
echo "[PASS] the deadline in force is reported"

# 0 restores the old unbounded behaviour. Asserted against a target that sleeps
# past a short explicit deadline, never against a real hang.
cat > "$TMP/slow" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
sleep 3
printf profile > "$p"
exit 0
EOF
chmod +x "$TMP/slow"
out=$(run_report -e "$TMP/slow @@ /dev/null" --queue-timeout 1)
printf '%s\n' "$out" | grep -q 'Queue replay *: 0 ok, 0 failed, 3 timed out' \
  || die "a 1s deadline must kill a 3s input: $out"
out=$(run_report -e "$TMP/slow @@ /dev/null" --queue-timeout 0)
printf '%s\n' "$out" | grep -q 'Queue timeout *: unbounded' \
  || die "--queue-timeout 0 must report itself: $out"
printf '%s\n' "$out" | grep -q 'Queue replay *: 3 ok, 0 failed, 0 timed out' \
  || die "--queue-timeout 0 must not bound replay: $out"
echo "[PASS] --queue-timeout 0 restores unbounded replay"

# A bad value is rejected before anything runs.
out=$(run_report -e "$TMP/target @@" --queue-timeout 5s)
test $? -ne 0 || die "--queue-timeout must reject a value that is not a number"
printf '%s\n' "$out" | grep -q 'queue-timeout must be a non-negative integer' \
  || die "the rejection must name the option: $out"
echo "[PASS] test_queue_timeout"
