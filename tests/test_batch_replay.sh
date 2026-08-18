#!/usr/bin/env bash
# Feature test: --batch replays N queue inputs per process.
#
# One process per input pays a fork, an exec and a full profile write for every
# corpus entry, and the profile write is sized by the binary's counter count,
# not by the input. Batch replay amortises all three. It used to be reachable
# only for a binary carrying the cov-analysis driver signature, so a libFuzzer
# binary or a hand-written argv loop — both of which take several input files on
# argv — silently replayed one input per process and a large corpus was
# impractical.
#
# The target below records how many input files each invocation received, so
# the batching is asserted directly rather than inferred from a wall clock.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
mkdir -p "$TOOLS" "$TMP/out/queue"

INPUTS=10
for i in $(seq 0 $((INPUTS - 1))); do
  printf 'input%s' "$i" > "$TMP/out/queue/id:00000$i,time:0,src:000"
done

# Two targets, identical but for the driver signature cov-analysis greps for.
make_target() {
  local path="$1" signature="$2"
  cat > "$path" <<EOF
#!/bin/bash
$signature
printf '%s\n' "\$#" >> "\$BATCH_LOG"
p="\${LLVM_PROFILE_FILE//%p/\$\$}"
mkdir -p "\$(dirname "\$p")"
printf profile > "\$p"
EOF
  chmod +x "$path"
}
make_target "$TMP/driver"   ': ###SIGNATURE_LLVMFUZZERTESTONEINPUT_COVERAGE###'
make_target "$TMP/nodriver" ':'

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
exit 0
EOF
cat > "$TOOLS/llvm-cov" <<'EOF'
#!/bin/bash
cmd="$1"
shift
case "$cmd" in
  show)
    out=""; fmt=""
    for arg in "$@"; do
      case "$arg" in -output-dir=*) out="${arg#*=}" ;; -format=*) fmt="${arg#*=}" ;; esac
    done
    mkdir -p "$out/coverage"
    if test "$fmt" = html; then
      printf '<html><body><table></table></body></html>\n' > "$out/index.html"
      printf 'body{}\n' > "$out/style.css"
    else
      printf '/tmp/source.c:\n    1|      1| int f(void);\n' > "$out/coverage/source.txt"
    fi
    ;;
  report)
    perfunc=0
    for arg in "$@"; do test "$arg" = -show-functions && perfunc=1; done
    if test "$perfunc" -eq 1; then
      printf "File '/tmp/source.c':\nName Regions Miss Cover Lines Miss Cover Branches Miss Cover\nf 1 0 100.00%% 1 0 100.00%% 0 0 -\nTOTAL 1 0 100.00%% 1 0 100.00%% 0 0 -\n"
    else
      printf 'summary\n'
    fi
    ;;
  export)
    lcov=0
    for arg in "$@"; do test "$arg" = --format=lcov && lcov=1; done
    if test "$lcov" -eq 1; then
      printf 'SF:/tmp/source.c\nDA:1,1\nend_of_record\n'
    else
      printf '{"data":[{"files":[{"filename":"/tmp/source.c","segments":[[1,1,1,true,true]]}],"functions":[{"name":"f","count":1,"filenames":["/tmp/source.c"],"regions":[[1,1,1,12,1,0,0,0]]}]}]}\n'
    fi
    ;;
esac
EOF
chmod +x "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export CC=/bin/true

# Replay a corpus and print "<invocations> <total inputs> <largest batch>".
replay() {
  local target="$1"; shift
  export BATCH_LOG="$TMP/batches"
  : > "$BATCH_LOG"
  rm -rf "$TMP/rep"
  PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report -d "$TMP/out" \
    -e "$target @@" --binary "$target" -o "$TMP/rep" --replay-only \
    "$@" > "$TMP/log" 2>&1 \
    || die "replay failed: $(cat "$TMP/log")"
  batch_shape "$BATCH_LOG"
}

batch_shape() {
  awk '{ n++; total += $1; if ($1 > max) max = $1 }
       END { printf "%d %d %d\n", n + 0, total + 0, max + 0 }' "$1"
}

# ── resolve_batch_size: the decision itself ───────────────────────────────────
# Sourcing cov-analysis brings its `set -e` along; this file handles its own
# failures, so it is turned straight back off.
source ./cov-analysis
set +e

assert_eq "$(resolve_batch_size './cov @@' 1 '')" "$BATCH_SIZE_DEFAULT" \
  "a driver binary with a trailing @@ must batch by default"
assert_eq "$(resolve_batch_size './cov @@' 0 '')" "0" \
  "a non-driver binary must not batch unless asked"
assert_eq "$(resolve_batch_size './cov @@' 0 '64')" "64" \
  "--batch must override the driver-signature autodetect"
assert_eq "$(resolve_batch_size './cov @@' 1 '1')" "0" \
  "--batch 1 must force one input per process"
assert_eq "$(resolve_batch_size './cov @@' 1 '0')" "0" \
  "--batch 0 must force one input per process"
assert_eq "$(resolve_batch_size './cov @@ -x' 1 '64')" "0" \
  "batching needs a trailing @@: the file list is appended to the command"
assert_eq "$(resolve_batch_size './cov' 1 '64')" "0" \
  "stdin replay cannot batch"
echo "[PASS] resolve_batch_size picks the batch size"

# ── autodetect is unchanged ───────────────────────────────────────────────────
read -r N TOTAL MAX < <(replay "$TMP/driver")
assert_eq "$TOTAL" "$INPUTS" "a driver binary must replay every input"
assert_eq "$N" "1" "a driver binary must still batch by default"
assert_eq "$MAX" "$INPUTS" "the default batch must hold the whole small corpus"

read -r N TOTAL MAX < <(replay "$TMP/nodriver")
assert_eq "$TOTAL" "$INPUTS" "a non-driver binary must replay every input"
assert_eq "$N" "$INPUTS" "a non-driver binary must default to one input per process"
assert_eq "$MAX" "1" "a non-driver binary must default to one input per process"
grep -q -- "--batch $BATCH_SIZE_DEFAULT" "$TMP/log" \
  || die "the demotion to one input per process must point at --batch"
echo "[PASS] the driver-signature autodetect is unchanged, and says so"

# ── --batch forces batching for any argv-taking binary ────────────────────────
read -r N TOTAL MAX < <(replay "$TMP/nodriver" --batch 4)
assert_eq "$TOTAL" "$INPUTS" "--batch must not lose an input"
assert_eq "$N" "3" "10 inputs at --batch 4 must take 3 processes"
assert_eq "$MAX" "4" "--batch 4 must put 4 inputs in a process"
grep -q "no per-input alarm" "$TMP/log" \
  || die "batching a binary without a per-input alarm must be reported"
echo "[PASS] --batch batches a binary that carries no driver signature"

# ── --batch 0 and 1 force the per-input loop, even for a driver binary ────────
for n in 0 1; do
  read -r N TOTAL MAX < <(replay "$TMP/driver" --batch "$n")
  assert_eq "$TOTAL" "$INPUTS" "--batch $n must not lose an input"
  assert_eq "$N" "$INPUTS" "--batch $n must replay one input per process"
  assert_eq "$MAX" "1" "--batch $n must replay one input per process"
done
echo "[PASS] --batch 0 and --batch 1 force one input per process"

# ── every input is replayed exactly once, whatever the batch size ─────────────
for n in 2 3 7 128; do
  read -r N TOTAL MAX < <(replay "$TMP/nodriver" --batch "$n")
  assert_eq "$TOTAL" "$INPUTS" "--batch $n replayed $TOTAL of $INPUTS inputs"
  test "$MAX" -le "$n" || die "--batch $n put $MAX inputs in one process"
done
echo "[PASS] batching replays every input exactly once at any size"

# ── refusals ──────────────────────────────────────────────────────────────────
rm -rf "$TMP/rep"
PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report -d "$TMP/out" \
  -e "$TMP/nodriver @@ -x" --binary "$TMP/nodriver" -o "$TMP/rep" \
  --replay-only --batch 8 > "$TMP/log" 2>&1 \
  && die "--batch without a trailing @@ must be refused"
grep -q -- "--batch 8 needs a coverage command ending in @@" "$TMP/log" \
  || die "the refusal must say why: $(cat "$TMP/log")"

rm -rf "$TMP/rep"
PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report -d "$TMP/out" \
  -e "$TMP/nodriver @@" --binary "$TMP/nodriver" -o "$TMP/rep" \
  --replay-only --batch many > "$TMP/log" 2>&1 \
  && die "a non-numeric --batch must be refused"
grep -q -- "--batch must be a non-negative integer" "$TMP/log" \
  || die "the refusal must say why: $(cat "$TMP/log")"
echo "[PASS] --batch refuses a command it cannot batch and a bad size"

# ── the batch size reaches every campaign of a multi-campaign run ─────────────
mkdir -p "$TMP/out2/queue"
for i in $(seq 0 3); do
  printf 'other%s' "$i" > "$TMP/out2/queue/id:00000$i,time:0,src:000"
done
export BATCH_LOG="$TMP/batches"
: > "$BATCH_LOG"
rm -rf "$TMP/rep"
PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report \
  -d "$TMP/out"  -e "$TMP/nodriver @@" --binary "$TMP/nodriver" --name one \
  -d "$TMP/out2" -e "$TMP/nodriver @@" --binary "$TMP/nodriver" --name two \
  -o "$TMP/rep" --batch 4 -q > "$TMP/log" 2>&1 \
  || die "multi-campaign report failed: $(cat "$TMP/log")"
read -r N TOTAL MAX < <(batch_shape "$BATCH_LOG")
assert_eq "$TOTAL" "$((INPUTS + 4))" "both campaigns must replay every input"
assert_eq "$MAX" "4" "--batch must reach each campaign of a multi-campaign run"
echo "[PASS] --batch reaches every campaign"

# ── the batch size reaches a remote replay ────────────────────────────────────
# ssh and scp run the "remote" side locally, as in test_remote_replay.sh.
cat > "$TOOLS/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_LOG"
shift
bash -c "$*"
EOF
cat > "$TOOLS/scp" <<'EOF'
#!/bin/bash
args=()
while test $# -gt 0; do
  case "$1" in
    -o|-p|-P|-i|-F|-J|-l) shift 2 ;;
    -*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
cp -- "${args[0]#somehost:}" "${args[1]#somehost:}"
EOF
chmod +x "$TOOLS/ssh" "$TOOLS/scp"
export SSH_LOG="$TMP/ssh.log"
: > "$SSH_LOG"
: > "$BATCH_LOG"
rm -rf "$TMP/rep"
PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report \
  --remote somehost -d "$TMP/out" -e "$TMP/nodriver @@" \
  --binary "$TMP/nodriver" -o "$TMP/rep" --batch 5 -q > "$TMP/log" 2>&1 \
  || die "remote replay failed: $(cat "$TMP/log")"
grep -q -- "--batch 5" "$SSH_LOG" \
  || die "--batch must be passed to the remote replay: $(cat "$SSH_LOG")"
read -r N TOTAL MAX < <(batch_shape "$BATCH_LOG")
assert_eq "$TOTAL" "$INPUTS" "the remote replay must replay every input"
assert_eq "$MAX" "5" "--batch must take effect on the remote side"
echo "[PASS] --batch reaches a remote replay"

echo "[PASS] test_batch_replay"
