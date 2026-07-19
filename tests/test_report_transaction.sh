#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
CORPUS="$TMP/corpus"
mkdir -p "$TOOLS" "$CORPUS"
printf seed > "$CORPUS/seed"
printf '{"reachable":[{"mangled":"f"}],"unreachable_defined":[]}' > "$TMP/reach.json"
printf '{bad' > "$TMP/malformed.json"

cat > "$TMP/target" <<'EOF'
#!/bin/bash
test "${FAIL_STAGE:-}" = replay && exit 9
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
cat > "$TOOLS/llvm-profdata" <<'EOF'
#!/bin/bash
test "${FAIL_STAGE:-}" = merge && exit 10
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
    test "${FAIL_STAGE:-}" = "$fmt" && exit 11
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
      test "${FAIL_STAGE:-}" = perfunc && exit 12
      printf "File '/tmp/source.c':\nName Regions Miss Cover Lines Miss Cover Branches Miss Cover\nf 1 0 100.00%% 1 0 100.00%% 0 0 -\nTOTAL 1 0 100.00%% 1 0 100.00%% 0 0 -\n"
    else
      test "${FAIL_STAGE:-}" = report && exit 13
      printf 'summary\n'
    fi
    ;;
  export)
    test "${FAIL_STAGE:-}" = export && exit 14
    printf '{"data":[{"files":[{"filename":"/tmp/source.c","segments":[[1,1,1,true,true],[2,1,0,false,false]]}],"functions":[{"name":"f","count":1,"filenames":["/tmp/source.c"],"regions":[[1,1,1,12,1,0,0,0]]}]}],"tag":"%s"}\n' "${EXPORT_TAG:-default}"
    ;;
esac
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export PATH="$TOOLS:/usr/bin:/bin" CC=/bin/true

report() {
  bash ./cov-analysis report -d "$CORPUS" -e "$TMP/target @@" -o "$1" -q "${@:2}"
}

assert_same() {
  diff -r "$1" "$2" >/dev/null || die "$3"
}

UNRELATED="$TMP/unrelated"
mkdir -p "$UNRELATED/html" "$UNRELATED/text"
printf keep > "$UNRELATED/html/KEEP"
printf keep > "$UNRELATED/text/KEEP"
if report "$UNRELATED" >"$TMP/unrelated.log" 2>&1; then
  die "unrelated non-empty destination should be refused"
fi
test -f "$UNRELATED/html/KEEP" && test -f "$UNRELATED/text/KEEP" \
  || die "unrelated html/text content was removed"

EMPTY="$TMP/empty"
mkdir "$EMPTY"
EXPORT_TAG=empty report "$EMPTY" || die "empty destination report failed"
test -f "$EMPTY/.cov-analysis-report" || die "empty destination was not marked"

DEST="$TMP/report"
EXPORT_TAG=first report "$DEST" || die "initial marked report failed"
test -f "$DEST/.cov-analysis-report" || die "initial report marker missing"
cp -a "$DEST" "$TMP/snapshot"

for stage in replay merge export; do
  if FAIL_STAGE="$stage" EXPORT_TAG="$stage" report "$DEST" >"$TMP/$stage.log" 2>&1; then
    die "$stage failure should return nonzero"
  fi
  assert_same "$DEST" "$TMP/snapshot" "$stage failure changed the previous report"
done

if FAIL_STAGE=perfunc report "$DEST" --reachability "$TMP/reach.json" >"$TMP/perfunc.log" 2>&1; then
  die "per-function failure should return nonzero"
fi
assert_same "$DEST" "$TMP/snapshot" "per-function failure changed the previous report"

if report "$DEST" --reachability "$TMP/malformed.json" >"$TMP/malformed.log" 2>&1; then
  die "malformed reachability input should return nonzero"
fi
assert_same "$DEST" "$TMP/snapshot" "malformed reachability changed the previous report"

FAILPY="$TMP/fail-python"
mkdir "$FAILPY"
cat > "$FAILPY/python3" <<'EOF'
#!/bin/bash
test $# -eq 7 && exit 99
exec /usr/bin/python3 "$@"
EOF
chmod +x "$FAILPY/python3"
if PATH="$FAILPY:$PATH" report "$DEST" --reachability "$TMP/reach.json" >"$TMP/annotation.log" 2>&1; then
  die "annotation failure should return nonzero"
fi
assert_same "$DEST" "$TMP/snapshot" "annotation failure changed the previous report"

MVTOOLS="$TMP/fail-mv"
mkdir "$MVTOOLS"
cat > "$MVTOOLS/mv" <<'EOF'
#!/bin/bash
test "${1:-}" = --version && exec /usr/bin/mv "$@"
n=0
test -f "$MV_COUNT" && n=$(cat "$MV_COUNT")
n=$((n + 1))
printf '%s' "$n" > "$MV_COUNT"
test "$n" -eq 2 && exit 88
exec /usr/bin/mv "$@"
EOF
chmod +x "$MVTOOLS/mv"
export MV_COUNT="$TMP/mv-count"
if PATH="$MVTOOLS:$PATH" EXPORT_TAG=publish-fail report "$DEST" >"$TMP/publish.log" 2>&1; then
  die "publication rename failure should return nonzero"
fi
assert_same "$DEST" "$TMP/snapshot" "publication failure did not restore the previous report"

EXPORT_TAG=second report "$DEST" || die "successful second report failed"
grep -q '"tag":"first"' "$DEST/coverage_old.json" || die "previous JSON was not preserved"
grep -q '"tag":"second"' "$DEST/coverage.json" || die "new JSON was not published"
test -s "$DEST/html/index.html" && test -d "$DEST/text" && test -s "$DEST/summary.txt" \
  && test -s "$DEST/coverage.profdata" || die "published artifact set is incomplete"

LEGACY="$TMP/legacy"
cp -a "$DEST" "$LEGACY"
rm "$LEGACY/.cov-analysis-report"
if report "$LEGACY" >"$TMP/legacy-refuse.log" 2>&1; then
  die "unmarked pre-marker report should require explicit migration"
fi
EXPORT_TAG=migrated report "$LEGACY" --migrate-existing-report || die "explicit legacy migration failed"
test -f "$LEGACY/.cov-analysis-report" || die "migrated report marker missing"

mkdir -p "$TMP/dot/a"
EXPORT_TAG=dot report "$TMP/dot/a/../dot-report" || die "normalized .. destination failed"
test -f "$TMP/dot/dot-report/.cov-analysis-report" || die ".. destination was not normalized"

mkdir "$TMP/symlink-target"
ln -s "$TMP/symlink-target" "$TMP/symlink-report"
EXPORT_TAG=symlink report "$TMP/symlink-report" || die "symlink destination failed"
test -L "$TMP/symlink-report" || die "report destination symlink was replaced"
test -f "$TMP/symlink-target/.cov-analysis-report" || die "symlink target report marker missing"

echo "[PASS] test_report_transaction"
