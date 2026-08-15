#!/usr/bin/env bash
# Regression test: replay must report progress while it runs.
#
# Field report: "[+] Replaying 12299 queue files..." and then silence for two
# hours. There was no way to tell a slow replay from a wedged one without
# inspecting worker ages with ps.
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
for i in $(seq 0 11); do
  printf x > "$TMP/out/queue/id:00000$i,time:0,src:000"
done

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
# Slow enough that a 12-input corpus spans several progress intervals.
cat > "$TMP/target" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
sleep 1
exit 0
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export CC=/bin/true

run_report() {
  rm -rf "$TMP/rep"
  PATH="$TOOLS:/usr/bin:/bin" timeout 180 bash "$ROOT/cov-analysis" report \
    -d "$TMP/out" -e "$TMP/target @@ /dev/null" -o "$TMP/rep" -t 2 "$@"
}

run_report > "$TMP/stdout" 2> "$TMP/stderr"
assert_eq "$?" "0" "the run failed: $(cat "$TMP/stderr")"

lines=$(grep -c 'queue files: .* done, .*/s, ~.*s left' "$TMP/stderr")
test "$lines" -ge 2 || die "expected at least two progress lines, got $lines: $(cat "$TMP/stderr")"
grep -q 'queue files: .* done' "$TMP/stdout" \
  && die "progress must not pollute stdout: $(cat "$TMP/stdout")"
echo "[PASS] replay reports progress on stderr"

# Counts only ever grow, and the last one accounts for the whole corpus.
counts=$(sed -n 's/.*queue files: \([0-9]*\) done.*/\1/p' "$TMP/stderr")
prev=0
for c in $counts; do
  test "$c" -ge "$prev" || die "progress went backwards: $counts"
  test "$c" -le 12 || die "progress overshot the corpus: $counts"
  prev="$c"
done
grep -q 'Queue replay *: 12 ok' "$TMP/stderr" "$TMP/stdout" \
  || die "the final tally must still account for every input"
echo "[PASS] progress counts are monotonic and bounded by the corpus"

run_report -q > "$TMP/stdout.q" 2> "$TMP/stderr.q"
assert_eq "$?" "0" "the quiet run failed: $(cat "$TMP/stderr.q")"
grep -q 'queue files: .* done' "$TMP/stderr.q" \
  && die "-q must suppress progress: $(cat "$TMP/stderr.q")"
echo "[PASS] -q suppresses progress"

echo "[PASS] test_replay_progress"
