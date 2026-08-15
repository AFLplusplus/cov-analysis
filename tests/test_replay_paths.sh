#!/usr/bin/env bash
# Regression test: replay must hand the target absolute input paths, and must
# account for replay outcomes instead of discarding them.
#
# Field report: a harness that chdir()s into its sandbox silently broke every
# relative corpus path after the first input. Every input failed to open, the
# run still reported success, and the coverage number was wrong.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
SANDBOX="$TMP/sandbox"
mkdir -p "$TOOLS" "$SANDBOX" "$TMP/out/queue" "$TMP/out/crashes"
printf a > "$TMP/out/queue/id:000000,time:0,src:000"
printf b > "$TMP/out/queue/id:000001,time:0,src:000"
printf c > "$TMP/out/queue/id:000002,time:0,src:000"
printf d > "$TMP/out/crashes/id:000000,sig:11,src:000"

# Writes its profile first (like a real coverage binary at exit), then chdir()s
# the way a real harness does and tries to open the input it was handed.
cat > "$TMP/target" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
cd "$SANDBOX" || exit 1
if ! test -r "$1"; then
  printf '%s\n' "$1" >> "$FAILLOG"
  exit 2
fi
case "$1" in
  *"$FAIL_MATCH") exit 7 ;;
esac
exit 0
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
    else
      printf '/tmp/source.c:\n    1|      1| int f(void);\n' > "$out/coverage/source.txt"
    fi
    ;;
  report) printf 'summary\n' ;;
  export) printf '{"data":[{"files":[],"functions":[]}]}\n' ;;
esac
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export CC=/bin/true SANDBOX FAILLOG="$TMP/faillog" FAIL_MATCH="__never__"
: > "$FAILLOG"

# Runs cov-analysis from $TMP so that `-d out` is a relative path.
report_relative() {
  ( cd "$TMP" && PATH="$TOOLS:/usr/bin:/bin" \
      bash "$ROOT/cov-analysis" report -d out -e "$TMP/target @@" -o "$TMP/rep" "$@" 2>&1 )
}

rm -rf "$TMP/rep"
out=$(report_relative)
rc=$?
assert_eq "$rc" "0" "relative -d run failed: $out"
if test -s "$FAILLOG"; then
  die "target received unusable relative paths: $(cat "$FAILLOG")"
fi

printf '%s\n' "$out" | grep -q 'Queue replay *: 3 ok, 0 failed, 0 timed out' \
  || die "queue replay outcome was not reported: $out"
printf '%s\n' "$out" | grep -q 'Crash replay *: 1 exited cleanly, 0 reproduced' \
  || die "crash replay outcome was not reported: $out"
echo "[PASS] absolute input paths and replay accounting"

# Crash/timeout inputs are expected to die; they must never fail the run.
: > "$FAILLOG"
rm -rf "$TMP/rep"
out=$(FAIL_MATCH="sig:11,src:000" report_relative)
rc=$?
assert_eq "$rc" "0" "crash replay failures must not fail the run: $out"
printf '%s\n' "$out" | grep -q 'Crash replay *: 0 exited cleanly, 1 reproduced (non-zero exit, expected), 0 timed out' \
  || die "crash replay outcome was not counted: $out"
# A crash input that dies is the desired outcome. Calling it "failed" reads as
# a broken tool.
printf '%s\n' "$out" | grep -q 'Crash replay.*failed' \
  && die "the crash replay line must not call an expected crash a failure: $out"
echo "[PASS] crash replay outcomes are named as expected, not as failures"

# Every queue input failing means the measurement is wrong, not the target.
: > "$FAILLOG"
rm -rf "$TMP/rep"
out=$(FAIL_MATCH="src:000" report_relative)
rc=$?
test "$rc" -ne 0 || die "a run where every queue input failed must not report success: $out"
printf '%s\n' "$out" | grep -q -- '--max-replay-failures' \
  || die "the failure message must name the threshold option: $out"
test -e "$TMP/rep" && die "a failed run must not publish a report"
echo "[PASS] total queue replay failure is fatal"

# ... but the user can accept it explicitly.
: > "$FAILLOG"
rm -rf "$TMP/rep"
out=$(FAIL_MATCH="src:000" report_relative --max-replay-failures 100)
rc=$?
assert_eq "$rc" "0" "--max-replay-failures 100 must accept a fully failing corpus: $out"
test -s "$TMP/rep/coverage.json" || die "report was not published with the raised threshold"
echo "[PASS] --max-replay-failures raises the threshold"

echo "[PASS] test_replay_paths"
