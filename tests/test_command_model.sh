#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
BINTOOLS="$TMP/tools"
CORPUS="$TMP/corpus"
mkdir -p "$BINTOOLS" "$CORPUS"
printf one > "$CORPUS/one"
printf two > "$CORPUS/two"

cat > "$BINTOOLS/llvm-profdata" <<'EOF'
#!/bin/bash
out=""
while test $# -gt 0; do
  if test "$1" = -o; then out="$2"; shift 2; else shift; fi
done
printf merged > "$out"
EOF
cat > "$BINTOOLS/llvm-cov" <<'EOF'
#!/bin/bash
cmd="$1"
shift
case "$cmd" in
  show)
    out=""; fmt=""
    for arg in "$@"; do
      case "$arg" in -output-dir=*) out="${arg#*=}";; -format=*) fmt="${arg#*=}";; esac
    done
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
      printf 'SF:/src/model.c\nDA:1,1\nend_of_record\n'
    else
      printf '{"data":[]}\n'
    fi
    ;;
esac
EOF
DRIVER="$TMP/binary with spaces"
cat > "$DRIVER" <<'EOF'
#!/bin/bash
signature='###SIGNATURE_LLVMFUZZERTESTONEINPUT_COVERAGE###'
seen=0
for arg in "$@"; do
  if test -f "$arg"; then
    seen=1
    value=$(tr -d '\n' < "$arg")
    printf '%s\n' "$value" >> "$TRACE_FILE"
  fi
done
if test "$seen" -eq 0; then
  value=$(tr -d '\n')
  printf '%s\n' "$value" >> "$TRACE_FILE"
fi
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
STDIN_BIN="$TMP/stdin-target"
cat > "$STDIN_BIN" <<'EOF'
#!/bin/bash
value=$(tr -d '\n')
printf '%s\n' "$value" >> "$TRACE_FILE"
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
WRAPPER="$TMP/wrapper"
cat > "$WRAPPER" <<'EOF'
#!/bin/bash
exec "$@"
EOF
chmod +x "$BINTOOLS/llvm-profdata" "$BINTOOLS/llvm-cov" "$DRIVER" "$STDIN_BIN" "$WRAPPER"
export PATH="$BINTOOLS:/usr/bin:/bin" CC=/bin/true

run_case() {
  local label="$1" command="$2" binary="$3" trace outdir
  trace="$TMP/$label.trace"
  outdir="$TMP/$label.out"
  : > "$trace"
  TRACE_FILE="$trace" bash ./cov-analysis report -d "$CORPUS" -e "$command" \
    --binary "$binary" -o "$outdir" -q || die "$label report failed"
  sort "$trace" > "$trace.sorted"
  assert_eq "$(tr '\n' ' ' < "$trace.sorted")" "one two " "$label replay inputs"
}

if bash ./cov-analysis report -d "$CORPUS" -e "\"$DRIVER\" @@" -o "$TMP/reject-quoted" -q \
  >"$TMP/reject-quoted.log" 2>&1; then
  die "quoted binary path without --binary should fail"
fi
grep -q -- '--binary <path>' "$TMP/reject-quoted.log" || die "quoted-path failure did not request --binary"

if bash ./cov-analysis report -d "$CORPUS" -e "$WRAPPER $STDIN_BIN @@" -o "$TMP/reject-wrapper" -q \
  >"$TMP/reject-wrapper.log" 2>&1; then
  die "wrapper command without --binary should fail"
fi

run_case trailing "\"$DRIVER\" @@" "$DRIVER"
run_case mid "\"$DRIVER\" --input @@ --tail" "$DRIVER"
run_case bash_syntax "[[ 1 -eq 1 ]] && \"$DRIVER\" @@" "$DRIVER"
run_case env_command "env MODEL=test \"$DRIVER\" @@" "$DRIVER"
run_case wrapper "$WRAPPER \"$DRIVER\" @@" "$DRIVER"
run_case stdin "\"$STDIN_BIN\"" "$STDIN_BIN"

: > "$TMP/search.trace"
out=$(TRACE_FILE="$TMP/search.trace" bash ./cov-analysis search /src/model.c:1 \
  -d "$CORPUS" -e "\"$DRIVER\" @@" --binary "$DRIVER" -q 2>/dev/null) \
  || die "search --binary command model failed"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2" "search --binary matches"

: > "$TMP/stability.trace"
TRACE_FILE="$TMP/stability.trace" bash ./cov-analysis stability -d "$CORPUS" \
  -e "\"$DRIVER\" @@" --binary "$DRIVER" -n 2 -q \
  || die "stability --binary command model failed"

echo "[PASS] test_command_model"
