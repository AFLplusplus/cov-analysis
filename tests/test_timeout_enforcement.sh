#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
cat > "$TMP/target" <<'EOF'
#!/bin/bash
value=""
for arg in "$@"; do
  if test -f "$arg"; then value=$(tr -d '\n' < "$arg"); break; fi
done
test -n "$value" || value=$(tr -d '\n')
mode="${MODE:-$value}"
p="${LLVM_PROFILE_FILE:-}"
if test -n "$p"; then
  p="${p//%p/$$}"
  mkdir -p "$(dirname "$p")"
  printf profile > "$p"
fi
case "$mode" in
  sleep)
    sleep 30
    ;;
  ignore)
    trap '' TERM
    while :; do sleep 1; done
    ;;
  fork)
    (
      trap '' TERM
      test -z "${PID_LOG:-}" || printf '%s\n' "$BASHPID" >> "$PID_LOG"
      while :; do sleep 1; done
    ) &
    wait
    ;;
esac
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
      printf '<html><body></body></html>\n' > "$out/index.html"
      printf 'body{}\n' > "$out/style.css"
    else
      printf 'text\n' > "$out/coverage/source.txt"
    fi
    ;;
  report)
    printf 'summary\n'
    ;;
  export)
    fmt=text
    for arg in "$@"; do case "$arg" in --format=*) fmt="${arg#*=}";; esac; done
    if test "$fmt" = lcov; then
      printf 'SF:/src/timeout.c\nDA:1,1\nend_of_record\n'
    else
      printf '{"data":[]}\n'
    fi
    ;;
esac
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export PATH="$TOOLS:/usr/bin:/bin" CC=/bin/true

elapsed_ms() {
  local start="$1" end
  end=$(date +%s%N)
  printf '%s\n' $(((end - start) / 1000000))
}

assert_dead() {
  local file="$1" pid tries state
  test -f "$file" || return 0
  for pid in $(sort -u "$file"); do
    for tries in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
      test "$state" = Z && break
      sleep 0.1
    done
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null && test "$state" != Z; then
      kill -KILL "$pid" 2>/dev/null || true
      die "timed target child survived: $pid"
    fi
  done
}

printf sleep > "$TMP/input"
source ./cov-analysis
set +e
for mode in sleep ignore fork; do
  : > "$TMP/$mode.pids"
  export MODE="$mode" PID_LOG="$TMP/$mode.pids"
  start=$(date +%s%N)
  run_input_command 1 "$TMP/target @@" "$TMP/input" >/dev/null 2>&1
  ms=$(elapsed_ms "$start")
  test "$ms" -lt 4000 || die "$mode timeout exceeded bound: ${ms}ms"
  assert_dead "$TMP/$mode.pids"
done
unset MODE PID_LOG

SEARCH="$TMP/search"
mkdir "$SEARCH"
printf fork > "$SEARCH/seed"
export PID_LOG="$TMP/search-fork.pids"
: > "$PID_LOG"
start=$(date +%s%N)
out=$(bash ./cov-analysis search /src/timeout.c:1 -d "$SEARCH" -e "$TMP/target @@" -T 1 -q 2>/dev/null)
ms=$(elapsed_ms "$start")
assert_eq "$out" "$SEARCH/seed" "search fork match"
test "$ms" -lt 7000 || die "search union+worker timeout exceeded bound: ${ms}ms"
assert_dead "$PID_LOG"
unset PID_LOG

printf sleep > "$SEARCH/seed"
start=$(date +%s%N)
out=$(bash ./cov-analysis search /src/timeout.c:1 -d "$SEARCH" -e "$TMP/target" -T 1 -q 2>/dev/null)
ms=$(elapsed_ms "$start")
assert_eq "$out" "$SEARCH/seed" "search stdin match"
test "$ms" -lt 5000 || die "search stdin union+worker timeout exceeded bound: ${ms}ms"

REPORT_CORPUS="$TMP/report-corpus"
mkdir "$REPORT_CORPUS"
printf fast > "$REPORT_CORPUS/seed"
printf sleep > "$REPORT_CORPUS/crash-one"
for style in at stdin; do
  if test "$style" = at; then command="$TMP/target @@"; else command="$TMP/target"; fi
  start=$(date +%s%N)
  bash ./cov-analysis report -d "$REPORT_CORPUS" -e "$command" -T 1 -o "$TMP/report-$style" -q \
    || die "report $style timeout run failed"
  ms=$(elapsed_ms "$start")
  test "$ms" -lt 4000 || die "report $style crash timeout exceeded bound: ${ms}ms"
done

STABILITY="$TMP/stability"
mkdir "$STABILITY"
printf sleep > "$STABILITY/seed"
for style in at stdin; do
  if test "$style" = at; then command="$TMP/target @@"; else command="$TMP/target"; fi
  start=$(date +%s%N)
  bash ./cov-analysis stability -d "$STABILITY" -e "$command" -T 1 -n 2 -q \
    || die "stability $style timeout run failed"
  ms=$(elapsed_ms "$start")
  test "$ms" -lt 5000 || die "stability $style timeout exceeded bound: ${ms}ms"
done

echo "[PASS] test_timeout_enforcement"
