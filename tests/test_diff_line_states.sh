#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
SRC2="$TMP/two.c"
printf 'one\ntwo\n' > "$SRC2"
python3 - "$SRC2" "$TMP/old.json" "$TMP/new.json" <<'PYEOF'
import json
import sys

src, old_path, new_path = sys.argv[1:]
def root(segments):
    return {'data': [{'files': [{'filename': src, 'segments': segments}],
                      'functions': [{'name': 'f', 'count': 0, 'filenames': [src]}]}]}
json.dump(root([[1, 1, 0, True, True], [3, 1, 0, False, False]]), open(old_path, 'w'))
json.dump(root([[1, 1, 1, True, True], [2, 1, 0, True, True], [3, 1, 0, False, False]]), open(new_path, 'w'))
PYEOF
mkdir -p "$TMP/offby"
bash ./cov-analysis diff -o "$TMP/offby" "$TMP/old.json" "$TMP/new.json" >/dev/null || die "two-line diff failed"
python3 - "$TMP/offby/coverage_diff.html" <<'PYEOF' || die "two-line half-open interval reconstruction failed"
import re
import sys

s = open(sys.argv[1], encoding='utf-8').read()
def card(label):
    m = re.search(r'<div class="k">' + re.escape(label) + r'</div><div class="v">(\d+)</div>', s)
    return int(m.group(1)) if m else -1
assert card('Newly covered lines — all files') == 1
assert card('Still uncovered lines — all files') == 1
assert 'class="new-covered"><td class="ln">1</td>' in s
assert 'class="still-uncovered"><td class="ln">2</td>' in s
PYEOF

mkdir -p "$TMP/full" "$TMP/changed"
bash ./cov-analysis diff -o "$TMP/full" "$TMP/new.json" "$TMP/new.json" >/dev/null || die "identical full diff failed"
grep -q '<section id="file-' "$TMP/full/coverage_diff.html" || die "default diff omitted unchanged files"
grep -q 'Still uncovered lines — all files</div><div class="v">1</div>' "$TMP/full/coverage_diff.html" \
  || die "default identical diff omitted still-uncovered lines"
bash ./cov-analysis diff --only-changed -o "$TMP/changed" "$TMP/new.json" "$TMP/new.json" >/dev/null \
  || die "identical changed-only diff failed"
if grep -q '<section id="file-' "$TMP/changed/coverage_diff.html"; then
  die "--only-changed retained an unchanged file"
fi
grep -q 'Aggregate scope: changed files only' "$TMP/changed/coverage_diff.html" \
  || die "changed-only aggregate scope is not labeled"

SRC5="$TMP/five.c"
printf 'a\nb\nc\nd\ne\n' > "$SRC5"
python3 - "$SRC5" "$TMP/base5.json" "$TMP/upd5.json" <<'PYEOF'
import json
import sys

src, base_path, upd_path = sys.argv[1:]
def root(segments):
    return {'data': [{'files': [{'filename': src, 'segments': segments}], 'functions': []}]}
json.dump(root([[1, 1, 0, True, True], [6, 1, 0, False, False]]), open(base_path, 'w'))
json.dump(root([[1, 1, 1, True, True], [1, 5, 0, True, True],
                [2, 1, 0, True, True], [3, 4, 1, True, True]]), open(upd_path, 'w'))
PYEOF
mkdir -p "$TMP/transitions"
bash ./cov-analysis diff -o "$TMP/transitions" "$TMP/base5.json" "$TMP/upd5.json" >/dev/null \
  || die "transition diff failed"
python3 - "$TMP/transitions/coverage_diff.html" <<'PYEOF' || die "same-line/multi-line/terminal segment reconstruction failed"
import re
import sys

s = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'Newly covered lines — all files</div><div class="v">(\d+)</div>', s)
assert m and int(m.group(1)) == 4
m = re.search(r'Still uncovered lines — all files</div><div class="v">(\d+)</div>', s)
assert m and int(m.group(1)) == 1
assert max(map(int, re.findall(r'<td class="ln">(\d+)</td>', s))) <= 5
PYEOF

source ./cov-analysis
set +e
CLANG="$(detect_clang || true)"
if test -n "$CLANG"; then
  export CC="$CLANG"
  COVTOOL="$(find_tool llvm-cov || true)"
  PROFDATA="$(find_tool llvm-profdata || true)"
else
  COVTOOL=""
  PROFDATA=""
fi
if test -n "$CLANG" && test -n "$COVTOOL" && test -n "$PROFDATA"; then
  REALSRC="$TMP/nested_macro.c"
  cat > "$REALSRC" <<'EOF'
#define TOUCH(v) do { if ((v) > 0) { (v) += 1; } } while (0)
static int choose(int v) {
  if (v > 3) {
    TOUCH(v);
  } else {
    v -= 1;
  }
  return v;
}
int main(int argc, char **argv) {
  int v = argc + (argv[0][0] == 0);
  return choose(v) == 99;
}
EOF
  "$CLANG" -O0 -fprofile-instr-generate -fcoverage-mapping "$REALSRC" -o "$TMP/realcov" \
    || die "real diff fixture compilation failed"
  LLVM_PROFILE_FILE="$TMP/real.profraw" "$TMP/realcov" >/dev/null 2>&1
  "$PROFDATA" merge -sparse "$TMP/real.profraw" -o "$TMP/real.profdata" \
    || die "real diff fixture profile merge failed"
  "$COVTOOL" export "$TMP/realcov" --format=text "-instr-profile=$TMP/real.profdata" > "$TMP/real.json" \
    || die "real JSON export failed"
  "$COVTOOL" export "$TMP/realcov" --format=lcov "-instr-profile=$TMP/real.profdata" > "$TMP/real.lcov" \
    || die "real LCOV export failed"
  ZERO=$(awk -F'[:,]' '/^DA:/ && $3 + 0 == 0 { n++ } END { print n + 0 }' "$TMP/real.lcov")
  mkdir -p "$TMP/real-diff"
  bash ./cov-analysis diff -o "$TMP/real-diff" "$TMP/real.json" "$TMP/real.json" >/dev/null \
    || die "real compiled diff failed"
  GOT=$(python3 - "$TMP/real-diff/coverage_diff.html" <<'PYEOF'
import re
import sys
s = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'Still uncovered lines — all files</div><div class="v">(\d+)</div>', s)
print(m.group(1) if m else -1)
PYEOF
)
  assert_eq "$GOT" "$ZERO" "JSON segment states match LCOV uncovered lines"
  MAX_RENDERED=$(grep -o '<td class="ln">[0-9]*' "$TMP/real-diff/coverage_diff.html" | grep -o '[0-9]*' | sort -n | tail -n1)
  SOURCE_LINES=$(wc -l < "$REALSRC")
  test -z "$MAX_RENDERED" || test "$MAX_RENDERED" -le "$SOURCE_LINES" \
    || die "real diff rendered a line beyond EOF"
else
  echo "[SKIP] real LCOV oracle fixture (need matching clang/llvm-cov/llvm-profdata)"
fi

echo "[PASS] test_diff_line_states"
