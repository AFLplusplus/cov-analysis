#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
source tests/lib.sh

TMP=$(mktmp)
JOB=""
trap 'test -n "$JOB" && kill -KILL -- -"$JOB" 2>/dev/null; rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
mkdir -p "$TOOLS" "$TMP/corpus" "$TMP/tmpdir"
for i in 1 2 3; do printf 'in%s' "$i" > "$TMP/corpus/in$i"; done

cat > "$TMP/target" <<'EOF'
#!/bin/bash
printf '%s\n' "$LLVM_PROFILE_FILE" >> "$TRACE_FILE"
sleep 1
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
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
test "$1" = export || exit 0
printf 'SF:/src/x.c\nDA:1,1\nend_of_record\n'
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export CC=/bin/true TRACE_FILE="$TMP/trace" TMPDIR="$TMP/tmpdir"

interrupt_after_first_start() {
  local label="$1"; shift
  : > "$TRACE_FILE"
  set -m
  PATH="$TOOLS:/usr/bin:/bin" bash "$ROOT/cov-analysis" "$@" > "$TMP/$label.log" 2>&1 &
  JOB=$!
  set +m
  local i
  for i in $(seq 1 100); do
    test -s "$TRACE_FILE" && break
    sleep 0.1
  done
  test -s "$TRACE_FILE" || die "$label never started a replay: $(cat "$TMP/$label.log")"
  kill -INT -- -"$JOB"
  for i in $(seq 1 50); do
    kill -0 "$JOB" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$JOB" 2>/dev/null; then
    die "$label kept running after Ctrl-C: $(cat "$TMP/$label.log")"
  fi
  wait "$JOB"
  RC=$?
  JOB=""
}

interrupt_after_first_start stability stability -d "$TMP/corpus" \
  -e "$TMP/target @@" -n 4 -T 10
assert_eq "$RC" "130" "stability must exit 130 on Ctrl-C"
grep -q 'run_2/' "$TRACE_FILE" \
  && die "stability started another pass after Ctrl-C: $(cat "$TRACE_FILE")"
sleep 2
grep -q 'run_[234]/' "$TRACE_FILE" \
  && die "stability started another pass after Ctrl-C: $(cat "$TRACE_FILE")"
assert_eq "$(ls -A "$TMP/tmpdir")" "" "stability must remove its workspace on Ctrl-C"
echo "[PASS] Ctrl-C stops stability and removes its workspace"

interrupt_after_first_start search search /src/x.c:1 -d "$TMP/corpus" \
  -e "$TMP/target @@" -T 10
assert_eq "$RC" "130" "search must exit 130 on Ctrl-C"
grep -q 'No .profraw files generated' "$TMP/search.log" \
  && die "search carried on after Ctrl-C: $(cat "$TMP/search.log")"
sleep 2
assert_eq "$(ls -A "$TMP/tmpdir")" "" "search must remove its workspace on Ctrl-C"
echo "[PASS] Ctrl-C stops search and removes its workspace"

echo "[PASS] test_interrupt"
