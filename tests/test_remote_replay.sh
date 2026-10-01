#!/usr/bin/env bash
# Feature test: --remote replays where the corpus lives and brings back only
# the merged profile.
#
# Field report: ~32k queue files were rsynced down just to replay them locally.
# Replaying on the box and fetching one coverage.profdata is the whole point,
# so this test asserts that no corpus is transferred, that the script ships
# itself, and that the remote working directory is always cleaned up.
#
# ssh and scp are stubs that execute locally, so the round-trip is real without
# needing a second machine.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
source tests/lib.sh

TMP=$(mktmp)
JOB=""
trap 'test -n "$JOB" && kill -KILL -- -"$JOB" 2>/dev/null; pkill -f -- "$TMP/remote/" 2>/dev/null; rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
CORPUS="$TMP/corpus"
mkdir -p "$TOOLS" "$CORPUS"
printf seed > "$CORPUS/seed"

cat > "$TMP/target" <<'EOF'
#!/bin/bash
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
      printf '/src/a.c:\n    1|      1| int f(void);\n' > "$out/coverage/a.txt"
    fi
    ;;
  report)
    for arg in "$@"; do test "$arg" = -show-functions && {
      printf "File '/src/a.c':\nName Regions Miss Cover Lines Miss Cover Branches Miss Cover\nf 4 1 75.00%% 3 1 66.67%% 0 0 -\nTOTAL 4 1 75.00%% 3 1 66.67%% 0 0 -\n"
      exit 0
    }; done
    printf 'summary\n'
    ;;
  export) printf '{"data":[{"files":[{"filename":"/src/a.c","segments":[]}],"functions":[]}]}\n' ;;
esac
EOF

# ── ssh/scp stubs: run locally, log every invocation ─────────────────────────
cat > "$TOOLS/ssh" <<'EOF'
#!/bin/bash
printf 'ssh' >> "$SSH_LOG"
for a in "$@"; do printf ' [%s]' "$a" >> "$SSH_LOG"; done
printf '\n' >> "$SSH_LOG"
host=""
while test $# -gt 0; do
  case "$1" in
    -o|-p|-P|-i|-F|-J|-l) shift 2 ;;
    -*) shift ;;
    *) host="$1"; shift; break ;;
  esac
done
test "$host" = "$EXPECT_HOST" || { echo "unexpected host: $host" >&2; exit 255; }
case "${SSH_DROP:-}:$*" in
  1:*--replay-only*)
    setsid -f sh -c "$*" >/dev/null 2>&1
    sleep 1
    exit 255 ;;
esac
if test "$*" = "bash -s"; then
  script=$(cat)
  printf '%s\n' "$script" >> "$SSH_LOG"
  exec setsid -f -w sh -c "$*" <<< "$script"
fi
exec setsid -f -w sh -c "$*"
EOF
cat > "$TOOLS/scp" <<'EOF'
#!/bin/bash
printf 'scp' >> "$SSH_LOG"
for a in "$@"; do printf ' [%s]' "$a" >> "$SSH_LOG"; done
printf '\n' >> "$SSH_LOG"
args=()
while test $# -gt 0; do
  case "$1" in
    -o|-p|-P|-i|-F|-J|-l) shift 2 ;;
    -*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
src="${args[0]}"; dst="${args[1]}"
src="${src#"$EXPECT_HOST":}"
dst="${dst#"$EXPECT_HOST":}"
cp -- "$src" "$dst"
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov" "$TOOLS/ssh" "$TOOLS/scp"
export PATH="$TOOLS:/usr/bin:/bin" CC=/bin/true
export SSH_LOG="$TMP/ssh.log" EXPECT_HOST="fuzzbox"

: > "$SSH_LOG"
OUT="$TMP/report"
out=$(bash ./cov-analysis report --remote fuzzbox -d "$CORPUS" -e "$TMP/target @@" \
  --binary "$TMP/target" -o "$OUT" 2>&1) || die "remote report failed: $out"

test -s "$OUT/summary.txt" || die "no report was rendered locally: $out"
test -s "$OUT/coverage.profdata" || die "the profile was not fetched: $out"
test -s "$OUT/gaps.txt" || die "the rendered report has no gap inventory"
echo "[PASS] remote replay renders a full local report"

# The script must ship itself rather than require an install on the far side.
grep -q 'scp .*cov-analysis' "$SSH_LOG" \
  || die "the script was not copied to the remote host: $(cat "$SSH_LOG")"
# Only the profile comes back — never the corpus.
grep 'scp' "$SSH_LOG" | grep -q 'coverage.profdata' \
  || die "the merged profile was not fetched: $(cat "$SSH_LOG")"
if grep 'scp' "$SSH_LOG" | grep -q "$CORPUS"; then
  die "the corpus was transferred; only the profile should be: $(cat "$SSH_LOG")"
fi
grep -q 'replay-only' "$SSH_LOG" \
  || die "the remote side did not run --replay-only: $(cat "$SSH_LOG")"
grep -q 'rm -rf' "$SSH_LOG" \
  || die "the remote working directory was not cleaned up: $(cat "$SSH_LOG")"
echo "[PASS] the script ships itself, only the profile returns, remote temp is cleaned"

# ── ssh options are passed through ───────────────────────────────────────────
: > "$SSH_LOG"
bash ./cov-analysis report --remote fuzzbox --ssh-opts "-o Port=2222" -d "$CORPUS" \
  -e "$TMP/target @@" --binary "$TMP/target" -o "$TMP/report2" -q \
  >"$TMP/opts.log" 2>&1 || die "remote report with --ssh-opts failed: $(cat "$TMP/opts.log")"
grep -q '\[-o\] \[Port=2222\]' "$SSH_LOG" \
  || die "--ssh-opts was not passed to ssh: $(cat "$SSH_LOG")"
echo "[PASS] --ssh-opts reaches ssh and scp"

: > "$SSH_LOG"
bash ./cov-analysis report --remote fuzzbox \
  --ssh-opts "-o Port=2222 -o 'IdentityFile=$TMP/my key'" -d "$CORPUS" \
  -e "$TMP/target @@" --binary "$TMP/target" -o "$TMP/report6" -q \
  >"$TMP/quoted.log" 2>&1 || die "remote report with quoted --ssh-opts failed: $(cat "$TMP/quoted.log")"
grep '^ssh' "$SSH_LOG" | grep -qF "[-o] [IdentityFile=$TMP/my key]" \
  || die "a quoted --ssh-opts value was split for ssh: $(cat "$SSH_LOG")"
grep '^scp' "$SSH_LOG" | grep -qF "[-o] [IdentityFile=$TMP/my key]" \
  || die "a quoted --ssh-opts value was split for scp: $(cat "$SSH_LOG")"
: > "$SSH_LOG"
if bash ./cov-analysis report --remote fuzzbox --ssh-opts "-o 'Port=2222" -d "$CORPUS" \
     -e "$TMP/target @@" --binary "$TMP/target" -o "$TMP/report8" -q \
     >"$TMP/unbalanced.log" 2>&1; then
  die "--ssh-opts with an unbalanced quote must be refused"
fi
grep -q 'ssh-opts' "$TMP/unbalanced.log" \
  || die "the refusal must name --ssh-opts: $(cat "$TMP/unbalanced.log")"
test -s "$SSH_LOG" && die "nothing may reach the remote host with unusable --ssh-opts"
echo "[PASS] --ssh-opts keeps quoted values together"

# ── a failing remote replay cleans up and fails loudly ───────────────────────
: > "$SSH_LOG"
if bash ./cov-analysis report --remote fuzzbox -d "$CORPUS" \
     -e "/nonexistent/binary @@" --binary "$TMP/target" -o "$TMP/report3" \
     >"$TMP/fail.log" 2>&1; then
  die "a failing remote replay must not report success"
fi
test -e "$TMP/report3" && die "a failed remote run must not publish a report"
grep -q 'rm -rf' "$SSH_LOG" \
  || die "the remote working directory was not cleaned up after failure: $(cat "$SSH_LOG")"
echo "[PASS] a failed remote replay cleans up and does not publish"

mkdir -p "$TMP/slowcorpus"
for i in $(seq 1 10); do printf 's%s' "$i" > "$TMP/slowcorpus/s$i"; done
cat > "$TMP/slowtarget" <<'EOF'
#!/bin/bash
printf 'start\n' >> "$TRACE_FILE"
sleep 2
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
chmod +x "$TMP/slowtarget"
export TRACE_FILE="$TMP/remote-trace"
: > "$TRACE_FILE"
set -m
bash ./cov-analysis report --remote fuzzbox -d "$TMP/slowcorpus" \
  -e "$TMP/slowtarget @@" --binary "$TMP/slowtarget" -o "$TMP/report7" \
  --remote-dir "$TMP/remote" --queue-timeout 30 > "$TMP/interrupt.log" 2>&1 &
JOB=$!
set +m
for i in $(seq 1 100); do
  test -s "$TRACE_FILE" && break
  sleep 0.1
done
test -s "$TRACE_FILE" || die "the remote replay never started: $(cat "$TMP/interrupt.log")"
kill -INT -- -"$JOB"
for i in $(seq 1 200); do
  kill -0 "$JOB" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$JOB" 2>/dev/null && die "the local run kept running after Ctrl-C"
wait "$JOB"
rc=$?
JOB=""
test "$rc" -ne 0 || die "an interrupted remote run must not report success"
started=$(grep -c . "$TRACE_FILE")
sleep 3
assert_eq "$(grep -c . "$TRACE_FILE")" "$started" \
  "the remote replay kept starting inputs after Ctrl-C"
test -e "$TMP/remote" && die "Ctrl-C left the remote working directory behind"
test -e "$TMP/report7" && die "an interrupted remote run must not publish"
echo "[PASS] Ctrl-C stops the remote replay and removes its working directory"

: > "$TRACE_FILE"
if SSH_DROP=1 bash ./cov-analysis report --remote fuzzbox -d "$TMP/slowcorpus" \
     -e "$TMP/slowtarget @@" --binary "$TMP/slowtarget" -o "$TMP/report9" \
     --remote-dir "$TMP/remote" --queue-timeout 30 > "$TMP/drop.log" 2>&1; then
  die "a dropped connection must fail the run"
fi
test -s "$TRACE_FILE" || die "the remote replay never started: $(cat "$TMP/drop.log")"
started=$(grep -c . "$TRACE_FILE")
sleep 3
assert_eq "$(grep -c . "$TRACE_FILE")" "$started" \
  "the remote replay kept running after the connection dropped"
test -e "$TMP/remote" && die "a dropped connection left the remote working directory behind"
grep '^ssh' "$SSH_LOG" | grep -qF '[-o] [ConnectTimeout=15]' \
  || die "the cleanup ssh must not wait for the TCP timeout: $(cat "$SSH_LOG")"
echo "[PASS] a dropped connection stops the remote replay and removes its working directory"

# ── argument checks ──────────────────────────────────────────────────────────
if bash ./cov-analysis report --remote fuzzbox --profdata "$OUT/coverage.profdata" \
     --binary "$TMP/target" -o "$TMP/report4" >"$TMP/conflict.log" 2>&1; then
  die "--remote with --profdata must be rejected"
fi
if bash ./cov-analysis report --remote fuzzbox -d "$CORPUS" -e "$TMP/target @@" \
     -o "$TMP/report5" >"$TMP/nobinary.log" 2>&1; then
  die "--remote without a local --binary must be rejected"
fi
echo "[PASS] conflicting remote argument sets are rejected"

echo "[PASS] test_remote_replay"
