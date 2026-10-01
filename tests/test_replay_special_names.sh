#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis
set +e

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT

NAMES=(
  'seed&inject'
  'back\slash'
  'double\\back'
  'a b'
  'quote'"'"'s'
  'dq"x'
  '$(inject)'
  '`inject`'
  'semi;inject'
  'pipe|inject'
  'star*'
  'id:000001,orig:a&b c'
)

for name in "${NAMES[@]}"; do
  path="/x/$name"
  rendered="$(command_for_input 'printf "%s" @@' "$path")"
  got="$(bash -c "$rendered")"
  assert_eq "$got" "$path" "command_for_input round trip for '$name'"
done
rendered="$(command_for_input 'printf "%s|%s" @@ @@' "/x/a&b")"
assert_eq "$(bash -c "$rendered")" "/x/a&b|@@" "only the first @@ is replaced"
echo "[PASS] command_for_input quotes every special character"

TOOLS="$TMP/tools"
mkdir -p "$TOOLS" "$TMP/corpus"
for name in "${NAMES[@]}"; do
  printf '%s' "$name" > "$TMP/corpus/$name"
done
cat > "$TOOLS/inject" <<EOF
#!/bin/bash
: > "$TMP/injected"
EOF
cat > "$TMP/target" <<'EOF'
#!/bin/bash
test -f "$1" || exit 3
cat -- "$1" >> "$TRACE_FILE"
printf '\n' >> "$TRACE_FILE"
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
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
EOF
chmod +x "$TOOLS/inject" "$TMP/target" "$TOOLS/llvm-profdata"
export CC=/bin/true

expected="$(printf '%s\n' "${NAMES[@]}" | LC_ALL=C sort)"
export TRACE_FILE="$TMP/trace"
: > "$TRACE_FILE"
PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report -d "$TMP/corpus" \
  -e "$TMP/target @@" -o "$TMP/rep" --replay-only --batch 0 > "$TMP/log" 2>&1 \
  || die "replay failed: $(cat "$TMP/log")"
test -e "$TMP/injected" && die "an input file name was executed as a command"
grep -q 'did not replay cleanly' "$TMP/log" \
  && die "an input with special characters in its name failed: $(cat "$TMP/log")"
assert_eq "$(LC_ALL=C sort "$TRACE_FILE")" "$expected" "replayed inputs"
echo "[PASS] one input per process replays every special file name verbatim"

echo "[PASS] test_replay_special_names"
