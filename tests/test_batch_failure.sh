#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
mkdir -p "$TOOLS" "$TMP/out/queue"

INPUTS=12
for i in $(seq 10 $((10 + INPUTS - 1))); do
  printf 'ok%s' "$i" > "$TMP/out/queue/id:0000$i,time:0,src:000"
done

make_target() {
  local path="$1" signature="$2" flush="$3"
  cat > "$path" <<EOF
#!/bin/bash
$signature
p="\${LLVM_PROFILE_FILE//%p/\$\$}"
mkdir -p "\$(dirname "\$p")"
done_list=""
for f in "\$@"; do
  case "\$(cat -- "\$f")" in
    crash*)
      test "$flush" = 1 && printf '%s' "\$done_list" > "\$p"
      exit 134 ;;
    hang*) sleep 30 ;;
  esac
  done_list+="\$(cat -- "\$f")"\$'\n'
done
printf '%s' "\$done_list" > "\$p"
EOF
  chmod +x "$path"
}
make_target "$TMP/driver" ': ###SIGNATURE_LLVMFUZZERTESTONEINPUT_COVERAGE###' 1
make_target "$TMP/plain" ':' 0

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
: > "$out"
while IFS= read -r f; do cat -- "$f" >> "$out"; done < "$manifest"
EOF
printf '#!/bin/bash\nexit 0\n' > "$TOOLS/llvm-cov"
cat > "$TOOLS/timeout" <<'EOF'
#!/bin/bash
case "${DEADLINE_LOG:+set}:$3" in set:*[0-9]s) printf '%s\n' "$3" >> "$DEADLINE_LOG" ;; esac
exec /usr/bin/timeout "$@"
EOF
chmod +x "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov" "$TOOLS/timeout"
export CC=/bin/true

expected="$(for i in $(seq 10 $((10 + INPUTS - 1))); do printf 'ok%s\n' "$i"; done)"

replay() {
  local target="$1"; shift
  rm -rf "$TMP/rep"
  PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report -d "$TMP/out" \
    -e "$target @@" --binary "$target" -o "$TMP/rep" --replay-only \
    "$@" > "$TMP/log" 2>&1 \
    || die "replay failed: $(cat "$TMP/log")"
}

contributed() {
  grep -v '^$' "$TMP/rep/coverage.profdata" | LC_ALL=C sort
}

printf 'crash' > "$TMP/out/queue/id:000015,time:0,src:000,crash"
replay "$TMP/driver"
assert_eq "$(contributed)" "$expected" \
  "every non-crashing input of a driver batch must contribute exactly once"
grep -q "Queue replay   : $INPUTS ok, 1 failed, 0 timed out (of $((INPUTS + 1)))" "$TMP/log" \
  || die "only the crashing input may count as failed: $(cat "$TMP/log")"
grep -q 'Batch fallback : 1 of 1 batches failed as a whole' "$TMP/log" \
  || die "the run must say that a batch was replayed one input per process: $(cat "$TMP/log")"
echo "[PASS] a crash in a driver batch costs no other input its coverage"

replay "$TMP/plain" --batch 4
assert_eq "$(contributed)" "$expected" \
  "every non-crashing input of a plain batch must contribute exactly once"
grep -q "Queue replay   : $INPUTS ok, 1 failed, 0 timed out (of $((INPUTS + 1)))" "$TMP/log" \
  || die "only the crashing input may count as failed: $(cat "$TMP/log")"
echo "[PASS] a crash in a plain batch costs no other input its coverage"
rm -f "$TMP/out/queue/id:000015,time:0,src:000,crash"

printf 'hang' > "$TMP/out/queue/id:000016,time:0,src:000,hang"
replay "$TMP/plain" --batch 3 --queue-timeout 1
assert_eq "$(contributed)" "$expected" \
  "every input of a batch killed at its deadline must contribute exactly once"
grep -q "Queue replay   : $INPUTS ok, 0 failed, 1 timed out (of $((INPUTS + 1)))" "$TMP/log" \
  || die "only the hanging input may count as timed out: $(cat "$TMP/log")"
grep -q 'hang$' "$TMP/rep/slow_inputs.txt" \
  || die "the hanging input must be named in slow_inputs.txt"
echo "[PASS] a hang in a batch costs no other input its coverage"
rm -f "$TMP/out/queue/id:000016,time:0,src:000,hang"

replay "$TMP/driver"
assert_eq "$(contributed)" "$expected" "a clean batch must contribute each input once"
grep -q 'Batch fallback' "$TMP/log" \
  && die "a clean batch must not be reported as replayed one input per process: $(cat "$TMP/log")"
echo "[PASS] a clean batch is replayed once"

export DEADLINE_LOG="$TMP/deadlines"
: > "$DEADLINE_LOG"
replay "$TMP/driver" --batch 64 --queue-timeout 1
assert_eq "$(sort -u "$DEADLINE_LOG")" "${INPUTS}s" \
  "a driver batch must get one queue timeout per input, uncapped"
: > "$DEADLINE_LOG"
replay "$TMP/plain" --batch 64 --queue-timeout 1
assert_eq "$(sort -u "$DEADLINE_LOG")" "10s" \
  "a plain batch must get at most 10 queue timeouts"
unset DEADLINE_LOG
echo "[PASS] only a batch without a per-input alarm has a capped deadline"

cat > "$TMP/reject" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
for f in "$@"; do cat -- "$f"; printf '\n'; done > "$p"
exit 1
EOF
chmod +x "$TMP/reject"
replay "$TMP/reject" --batch 3 --max-replay-failures 100
assert_eq "$(contributed)" "$expected" "every input of a failed batch must contribute exactly once"
grep -q 'Batch fallback : 4 of 4 batches failed as a whole' "$TMP/log" \
  || die "the run must count the batches replayed one input per process: $(cat "$TMP/log")"
grep -q -- '--batch 0 runs each input once' "$TMP/log" \
  || die "a run whose batches mostly failed must point at --batch 0: $(cat "$TMP/log")"
echo "[PASS] a run says how many batches it replayed one input per process"

mkdir -p "$TMP/big/queue"
for i in $(seq 100 139); do
  printf 'ok%s' "$i" > "$TMP/big/queue/id:000$i,time:0,src:000"
done
printf 'hang' > "$TMP/big/queue/id:000140,time:0,src:000,hang"
rm -rf "$TMP/rep"
start=$(date +%s)
PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report -d "$TMP/big" \
  -e "$TMP/plain @@" --binary "$TMP/plain" -o "$TMP/rep" --replay-only \
  --batch 64 --queue-timeout 1 > "$TMP/log" 2>&1 \
  || die "replay failed: $(cat "$TMP/log")"
elapsed=$(( $(date +%s) - start ))
test "$elapsed" -lt 30 \
  || die "a hang held a batch of 41 inputs for ${elapsed}s; the batch deadline must be capped"
assert_eq "$(contributed | wc -l | tr -d ' ')" "40" "every input of the capped batch must contribute"
echo "[PASS] a hang holds its batch for a capped deadline only"

echo "[PASS] test_batch_failure"
