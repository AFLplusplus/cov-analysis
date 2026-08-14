#!/usr/bin/env bash
# Regression test: two replayed inputs must never write the same .profraw.
#
# LLVM_PROFILE_FILE=cov-%p.profraw names the profile after the process id. PIDs
# are reused once the kernel's counter wraps (pid_max is 32768 on many systems,
# and a queue can hold more inputs than that), and the second process silently
# overwrites the first one's counts.
#
# The target below expands %p to a FIXED value, so every input collides — the
# worst case of PID reuse. The stub llvm-profdata records how many profiles were
# merged, which must equal the number of replayed inputs.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
mkdir -p "$TOOLS" "$TMP/out/queue"
printf a > "$TMP/out/queue/id:000000,time:0,src:000"
printf b > "$TMP/out/queue/id:000001,time:0,src:000"
printf c > "$TMP/out/queue/id:000002,time:0,src:000"

cat > "$TMP/target" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/12345}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
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
printf merged > "$out"
test -n "$manifest" && grep -c . "$manifest" > "$MERGED_COUNT"
exit 0
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
export CC=/bin/true MERGED_COUNT="$TMP/merged_count"

# Loop mode: @@ embedded mid-command.
: > "$MERGED_COUNT"
PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report -d "$TMP/out" \
  -e "$TMP/target @@ --end" -o "$TMP/rep" -q >"$TMP/loop.log" 2>&1 \
  || die "loop-mode report failed: $(cat "$TMP/loop.log")"
assert_eq "$(cat "$MERGED_COUNT")" "3" "loop mode lost profiles to a profraw name collision"
echo "[PASS] loop mode gives every input its own profile"

# stdin mode: no @@ at all.
: > "$MERGED_COUNT"
rm -rf "$TMP/rep"
PATH="$TOOLS:/usr/bin:/bin" bash ./cov-analysis report -d "$TMP/out" \
  -e "$TMP/target" -o "$TMP/rep" -q >"$TMP/stdin.log" 2>&1 \
  || die "stdin-mode report failed: $(cat "$TMP/stdin.log")"
assert_eq "$(cat "$MERGED_COUNT")" "3" "stdin mode lost profiles to a profraw name collision"
echo "[PASS] stdin mode gives every input its own profile"

echo "[PASS] test_profile_collision"
