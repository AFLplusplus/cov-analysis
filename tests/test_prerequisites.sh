#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
printf '{"data":[]}' > "$TMP/old.json"
printf '{"data":[]}' > "$TMP/new.json"
mkdir "$TMP/empty-path"
if PATH="$TMP/empty-path" /bin/bash ./cov-analysis diff -o "$TMP/diff" \
  "$TMP/old.json" "$TMP/new.json" >"$TMP/python.out" 2>"$TMP/python.err"; then
  die "diff without python3 should fail"
fi
grep -q "requires 'python3'" "$TMP/python.err" || die "missing-python error is not actionable"

P="$TMP/no-timeout"
mkdir "$P" "$TMP/corpus"
printf x > "$TMP/corpus/seed"
for cmd in find xargs head grep mktemp realpath sort tr wc; do ln -s "$(command -v "$cmd")" "$P/$cmd"; done
if PATH="$P" /bin/bash ./cov-analysis report -d "$TMP/corpus" -e /bin/true -o "$TMP/report" \
  >"$TMP/timeout.out" 2>"$TMP/timeout.err"; then
  die "report without timeout should fail"
fi
grep -q "requires 'timeout'" "$TMP/timeout.err" || die "missing-timeout error is not actionable"

B="$TMP/bsd-find"
mkdir "$B"
printf '#!/bin/sh\necho "find version BSD"\n' > "$B/find"
chmod +x "$B/find"
for cmd in head grep; do ln -s "$(command -v "$cmd")" "$B/$cmd"; done
if PATH="$B" /bin/bash ./cov-analysis report -d "$TMP/corpus" -e /bin/true -o "$TMP/bsd-report" \
  >"$TMP/find.out" 2>"$TMP/find.err"; then
  die "report with non-GNU find should fail"
fi
grep -q 'requires GNU find' "$TMP/find.err" || die "non-GNU-find error is not actionable"

G="$TMP/no-gawk"
mkdir "$G"
for cmd in find xargs timeout head grep mktemp realpath sort tr wc basename dirname mkdir rm; do
  path=$(command -v "$cmd" 2>/dev/null || true)
  test -n "$path" && ln -s "$path" "$G/$cmd"
done
printf '#!/bin/sh\nexit 0\n' > "$G/llvm-profdata"
printf '#!/bin/sh\nexit 0\n' > "$G/llvm-cov"
printf '#!/bin/sh\necho "awk 1.0"\n' > "$G/awk"
printf '#!/bin/sh\nexit 0\n' > "$TMP/target"
chmod +x "$G/llvm-profdata" "$G/llvm-cov" "$G/awk" "$TMP/target"
if PATH="$G" CC=/bin/true /bin/bash ./cov-analysis stability -d "$TMP/corpus" \
  -e "$TMP/target @@" -n 2 >"$TMP/gawk.out" 2>"$TMP/gawk.err"; then
  die "stability without GNU awk should fail"
fi
grep -q 'requires GNU awk' "$TMP/gawk.err" || die "missing-gawk error is not actionable"

bash ./cov-analysis stability --help | grep -q -- '-T <secs>' \
  || die "stability help omits -T"
grep -A45 '^### cov-analysis stability' README.md | grep -q -- '-T <secs>' \
  || die "README stability options omit -T"

echo "[PASS] test_prerequisites"
