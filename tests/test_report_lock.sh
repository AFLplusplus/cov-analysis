#!/usr/bin/env bash
# Regression test: a report directory belongs to one run at a time, and what a
# killed run leaves behind can be cleared safely.
#
# Field report: an ssh client timeout left a run alive on the host; a second run
# against the same -o proceeded anyway. Cleaning up the staging directories by
# hand then hit one a live run still held, and the failure surfaced several
# steps later as a missing coverage.profdata.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
source tests/lib.sh
source ./cov-analysis
set +e   # sourcing cov-analysis enables `set -e`; we capture exit codes by hand

TMP=$(mktmp)
trap 'rm -rf "$TMP"; test -n "${HOLDER:-}" && kill "$HOLDER" 2>/dev/null' EXIT
TOOLS="$TMP/tools"
mkdir -p "$TOOLS" "$TMP/out/queue" "$TMP/work"
printf a > "$TMP/out/queue/id:000000,time:0,src:000"

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
exit 0
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export CC=/bin/true

REP="$TMP/work/rep"
LOCK="$TMP/work/.rep.cov-analysis.lock"

run_report() {
  PATH="$TOOLS:/usr/bin:/bin" timeout 120 bash "$ROOT/cov-analysis" report \
    -d "$TMP/out" -e "$TMP/target @@" -o "$REP" "$@" 2>&1
}

# A live holder: a process that exists for as long as the lock should.
sleep 300 &
HOLDER=$!
mkdir -p "$LOCK"
{
  printf 'pid %s\n' "$HOLDER"
  printf 'started %s\n' "$(pid_start_time "$HOLDER")"
  printf 'host %s\n' "$(this_host)"
} > "$LOCK/owner"
mkdir -p "$TMP/work/.rep.cov-analysis.stage.LIVEAA"

out=$(run_report)
rc=$?
test "$rc" -ne 0 || die "a second run against a held directory must not start: $out"
printf '%s\n' "$out" | grep -q "in use by cov-analysis (pid $HOLDER" \
  || die "the refusal must name the pid that holds the directory: $out"
printf '%s\n' "$out" | grep -q -- '--force' \
  || die "the refusal must name the way out: $out"
test -d "$TMP/work/.rep.cov-analysis.stage.LIVEAA" \
  || die "a refused run must not disturb the staging directory of the live run"
echo "[PASS] a held report directory refuses a second run"

# --clean must keep its hands off a directory a live run holds.
out=$(PATH="$TOOLS:/usr/bin:/bin" bash "$ROOT/cov-analysis" report -o "$REP" --clean 2>&1)
rc=$?
test "$rc" -ne 0 || die "--clean must refuse while a run holds the directory: $out"
test -d "$TMP/work/.rep.cov-analysis.stage.LIVEAA" \
  || die "--clean removed the staging directory of a live run"
test -d "$LOCK" || die "--clean removed a live lock"
echo "[PASS] --clean leaves a live run alone"

# --force takes the directory over.
out=$(run_report --force)
assert_eq "$?" "0" "--force must take over a held directory: $out"
printf '%s\n' "$out" | grep -q "Taking over the report directory from pid $HOLDER" \
  || die "--force must say that it took the directory over: $out"
test -s "$REP/coverage.json" || die "the forced run did not publish"
echo "[PASS] --force takes over a held directory"

# A lock whose holder is gone is broken automatically.
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
mkdir -p "$LOCK"
{
  printf 'pid %s\n' "$HOLDER"
  printf 'started %s\n' "12345"
  printf 'host %s\n' "$(this_host)"
} > "$LOCK/owner"
out=$(run_report)
assert_eq "$?" "0" "a lock whose holder is gone must be broken: $out"
echo "[PASS] a stale lock does not block a run"

# A recycled pid must not pass for the original holder.
sleep 300 &
HOLDER=$!
mkdir -p "$LOCK"
{
  printf 'pid %s\n' "$HOLDER"
  printf 'started %s\n' "1"
  printf 'host %s\n' "$(this_host)"
} > "$LOCK/owner"
report_lock_live "$LOCK" \
  && die "a pid with a different start time must not count as the lock holder"
kill "$HOLDER" 2>/dev/null
HOLDER=""
echo "[PASS] a recycled pid is not the lock holder"

# --clean removes what a killed run left, and nothing else.
rm -rf "$LOCK"
mkdir -p "$TMP/work/.rep.cov-analysis.stage.STALEA" \
         "$TMP/work/.rep.cov-analysis.stage.STALEB" "$LOCK"
mkdir -p "$TMP/work/.rep.cov-analysis.rollback.1.2"
out=$(PATH="$TOOLS:/usr/bin:/bin" bash "$ROOT/cov-analysis" report -o "$REP" --clean 2>&1)
assert_eq "$?" "0" "--clean failed: $out"
test -d "$TMP/work/.rep.cov-analysis.stage.STALEA" \
  && die "--clean left a stale staging directory behind"
test -d "$TMP/work/.rep.cov-analysis.stage.STALEB" \
  && die "--clean left a stale staging directory behind"
test -d "$LOCK" && die "--clean left a stale lock behind"
test -s "$REP/coverage.json" || die "--clean removed the published report"
test -d "$TMP/work/.rep.cov-analysis.rollback.1.2" \
  || die "--clean must not delete a rollback directory: it holds the previous report"
printf '%s\n' "$out" | grep -q 'rollback' \
  || die "--clean must report the rollback directory it left in place: $out"
echo "[PASS] --clean removes stale workspaces only"

# A run that is hung up on must not leave its staging directory behind.
cat > "$TMP/slow" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
sleep 30
EOF
chmod +x "$TMP/slow"
rm -rf "$REP"
PATH="$TOOLS:/usr/bin:/bin" bash "$ROOT/cov-analysis" report \
  -d "$TMP/out" -e "$TMP/slow @@" -o "$REP" --queue-timeout 0 >/dev/null 2>&1 &
RUN=$!
for _ in $(seq 1 100); do
  compgen -G "$TMP/work/.rep.cov-analysis.stage.*" >/dev/null && break
  sleep 0.1
done
compgen -G "$TMP/work/.rep.cov-analysis.stage.*" >/dev/null \
  || die "the run never created a staging directory"
kill -HUP "$RUN"
wait "$RUN" 2>/dev/null
for _ in $(seq 1 50); do
  compgen -G "$TMP/work/.rep.cov-analysis.stage.*" >/dev/null || break
  sleep 0.1
done
compgen -G "$TMP/work/.rep.cov-analysis.stage.*" >/dev/null \
  && die "a hung-up run left its staging directory behind"
test -d "$LOCK" && die "a hung-up run left its lock behind"
echo "[PASS] HUP cleans up like INT and TERM"

echo "[PASS] test_report_lock"
