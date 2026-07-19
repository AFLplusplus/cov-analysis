#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
CORPUS="$TMP/corpus"
mkdir -p "$TOOLS" "$CORPUS"
for i in $(seq 1 300); do printf x > "$CORPUS/input-$i"; done

python3 - "$TMP/export.json" "$TMP" <<'PYEOF'
import json
import os
import sys

out, base = sys.argv[1:]
files = []
for i in range(1, 201):
    name = 'path with spaces %d.c' % i
    if i == 199:
        name = 'quote"name.c'
    elif i == 200:
        name = 'back\\slash.c'
    files.append({'filename': os.path.join(base, 'source tree', name),
                  'segments': []})
json.dump({'data': [{'files': files, 'functions': []}]}, open(out, 'w'))
PYEOF
printf '{"reachable":[],"unreachable_defined":[]}' > "$TMP/reach.json"

cat > "$TMP/target" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
cat > "$TOOLS/llvm-profdata" <<'EOF'
#!/bin/bash
test $# -le 8 || exit 70
manifest=""; out=""
while test $# -gt 0; do
  case "$1" in
    --input-files=*) manifest="${1#*=}"; shift;;
    -o) out="$2"; shift 2;;
    *) shift;;
  esac
done
test -s "$manifest" || exit 71
wc -l < "$manifest" > "$PROFILE_LOG"
printf merged > "$out"
EOF
cat > "$TOOLS/llvm-cov" <<'EOF'
#!/bin/bash
test $# -le 16 || exit 80
cmd="$1"
shift
case "$cmd" in
  show)
    out=""; fmt=""
    for arg in "$@"; do case "$arg" in -output-dir=*) out="${arg#*=}";; -format=*) fmt="${arg#*=}";; esac; done
    mkdir -p "$out/coverage"
    if test "$fmt" = html; then
      printf '<html><body><table></table></body></html>\n' > "$out/index.html"
      printf 'body{}\n' > "$out/style.css"
    else
      printf 'text\n' > "$out/coverage/source.txt"
    fi
    ;;
  report)
    response=""
    for arg in "$@"; do case "$arg" in @*) response="${arg#@}";; esac; done
    if test -n "$response"; then
      /usr/bin/python3 - "$response" "$SOURCE_LOG" <<'PYEOF'
import shlex
import sys
tokens = shlex.split(open(sys.argv[1], encoding='utf-8').read(), posix=True)
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(tokens) + '\n')
PYEOF
      printf "File '/tmp/source.c':\nName Regions Miss Cover Lines Miss Cover Branches Miss Cover\nTOTAL 0 0 0 0 0 0 0 0 0\n"
    else
      printf 'summary\n'
    fi
    ;;
  export)
    cat "$EXPORT_JSON"
    ;;
esac
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export PATH="$TOOLS:/usr/bin:/bin" CC=/bin/true
export PROFILE_LOG="$TMP/profile-count" SOURCE_LOG="$TMP/source-args" EXPORT_JSON="$TMP/export.json"

bash ./cov-analysis report -d "$CORPUS" -e "$TMP/target @@" -o "$TMP/report" \
  --reachability "$TMP/reach.json" -q || die "large argument report failed"
assert_eq "$(tr -d ' ' < "$PROFILE_LOG")" "300" "profile manifest count"
assert_eq "$(wc -l < "$SOURCE_LOG" | tr -d ' ')" "200" "source response argument count"
grep -Fx "$TMP/source tree/path with spaces 1.c" "$SOURCE_LOG" >/dev/null \
  || die "source path containing spaces was split or lost"
grep -Fx "$TMP/source tree/quote\"name.c" "$SOURCE_LOG" >/dev/null \
  || die "source path containing a quote was altered"
grep -Fx "$TMP/source tree/back\\slash.c" "$SOURCE_LOG" >/dev/null \
  || die "source path containing a backslash was altered"
test -s "$TMP/report/coverage.profdata" || die "large profile merge output missing"
grep -q '^Reachable-only coverage' "$TMP/report/summary.txt" || die "reachable-only metrics missing"

echo "[PASS] test_large_argument_sets"
