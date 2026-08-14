#!/usr/bin/env bash
# Feature test: replay and rendering must be separable.
#
# Replaying 32k corpus files where they live and carrying back only the merged
# profile is the whole point of --replay-only / --profdata: it is what makes
# remote replay and multi-campaign merging possible, and it lets a report be
# re-rendered (new --ignore-regex, fresh reachability) without touching the
# corpus again.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
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
out=""; manifest=""
while test $# -gt 0; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --input-files=*) manifest="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
printf merged > "$out"
test -n "$manifest" && test -n "${MERGE_LOG:-}" && cp "$manifest" "$MERGE_LOG"
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
      printf '/src/a.c:\n    1|      1| int f(void);\n' > "$out/coverage/a.txt"
    fi
    ;;
  report)
    perfunc=0
    for arg in "$@"; do test "$arg" = -show-functions && perfunc=1; done
    if test "$perfunc" -eq 1; then
      cat <<'PERFUNC'
File '/src/a.c':
Name                        Regions    Miss   Cover     Lines    Miss   Cover  Branches    Miss   Cover
-------------------------------------------------------------------------------------------------------
kept                             10       4  60.00%         8       3  62.50%         4       2  50.00%
gone                              6       6   0.00%         5       5   0.00%         2       2   0.00%
-------------------------------------------------------------------------------------------------------
TOTAL                            16      10  37.50%        13       8  38.46%         6       4  33.33%
PERFUNC
    else
      printf 'summary for /src/a.c\n'
    fi
    ;;
  export)
    printf '{"data":[{"files":[{"filename":"/src/a.c","segments":[]}],"functions":[]}]}\n'
    ;;
esac
EOF
chmod +x "$TMP/target" "$TOOLS/llvm-profdata" "$TOOLS/llvm-cov"
export PATH="$TOOLS:/usr/bin:/bin" CC=/bin/true

# ── replay-only stops after the merged profile ───────────────────────────────
STAGE1="$TMP/profile-only"
bash ./cov-analysis report -d "$CORPUS" -e "$TMP/target @@" -o "$STAGE1" --replay-only -q \
  >"$TMP/replayonly.log" 2>&1 || die "replay-only failed: $(cat "$TMP/replayonly.log")"
test -s "$STAGE1/coverage.profdata" || die "replay-only produced no profile data"
test -f "$STAGE1/.cov-analysis-report" || die "replay-only output is not a marked artifact"
test -e "$STAGE1/html" && die "replay-only must not render a report"
test -e "$STAGE1/summary.txt" && die "replay-only must not render a summary"
echo "[PASS] --replay-only stops after the merged profile"

# ── rendering from that profile needs no corpus ──────────────────────────────
RENDERED="$TMP/rendered"
bash ./cov-analysis report --profdata "$STAGE1/coverage.profdata" \
  --binary "$TMP/target" -o "$RENDERED" -q >"$TMP/render.log" 2>&1 \
  || die "render from profdata failed: $(cat "$TMP/render.log")"
test -s "$RENDERED/summary.txt" || die "rendered report has no summary"
test -s "$RENDERED/gaps.txt" || die "rendered report has no gap inventory"
test -s "$RENDERED/html/index.html" || die "rendered report has no HTML"
echo "[PASS] --profdata renders without the corpus"

# ── and matches the equivalent single-shot run ───────────────────────────────
ONESHOT="$TMP/oneshot"
bash ./cov-analysis report -d "$CORPUS" -e "$TMP/target @@" -o "$ONESHOT" -q \
  >"$TMP/oneshot.log" 2>&1 || die "single-shot report failed: $(cat "$TMP/oneshot.log")"
diff "$ONESHOT/summary.txt" "$RENDERED/summary.txt" >/dev/null \
  || die "split rendering produced a different summary than the single-shot run"
diff "$ONESHOT/gaps.txt" "$RENDERED/gaps.txt" >/dev/null \
  || die "split rendering produced a different gap inventory"
echo "[PASS] split rendering matches the single-shot run"

# ── several profiles merge into one report ───────────────────────────────────
STAGE2="$TMP/profile-two"
bash ./cov-analysis report -d "$CORPUS" -e "$TMP/target @@" -o "$STAGE2" --replay-only -q \
  >"$TMP/replayonly2.log" 2>&1 || die "second replay-only failed"
MERGED="$TMP/merged"
MERGE_LOG="$TMP/merge-manifest" \
  bash ./cov-analysis report --profdata "$STAGE1/coverage.profdata" \
    --profdata "$STAGE2/coverage.profdata" --binary "$TMP/target" -o "$MERGED" -q \
    >"$TMP/merge.log" 2>&1 || die "merging two profiles failed: $(cat "$TMP/merge.log")"
grep -q "$STAGE1/coverage.profdata" "$TMP/merge-manifest" \
  || die "first profile was not merged: $(cat "$TMP/merge-manifest")"
grep -q "$STAGE2/coverage.profdata" "$TMP/merge-manifest" \
  || die "second profile was not merged: $(cat "$TMP/merge-manifest")"
echo "[PASS] several --profdata inputs merge"

# ── argument errors ──────────────────────────────────────────────────────────
if bash ./cov-analysis report -d "$CORPUS" -e "$TMP/target @@" -o "$TMP/x1" \
     --replay-only --profdata "$STAGE1/coverage.profdata" >"$TMP/both.log" 2>&1; then
  die "--replay-only with --profdata must be rejected"
fi
if bash ./cov-analysis report --profdata "$STAGE1/coverage.profdata" -o "$TMP/x2" \
     >"$TMP/nobin.log" 2>&1; then
  die "--profdata without a coverage binary must be rejected"
fi
if bash ./cov-analysis report --profdata "$TMP/does-not-exist.profdata" \
     --binary "$TMP/target" -o "$TMP/x3" >"$TMP/missing.log" 2>&1; then
  die "a missing --profdata input must be rejected"
fi
echo "[PASS] conflicting and incomplete argument sets are rejected"

echo "[PASS] test_replay_render_split"
