#!/usr/bin/env bash
# Verify reachability-aware annotation of llvm-cov's own reports: cross coverage
# with the fuzz-reachability tool's output and, in place,
#   - tint each function's lines in the HTML file view (dark grey = unreachable,
#     amber = reachable but not reached, shaded by confidence (high/medium/low),
#     purple = covered-yet-unreachable),
#   - mark the text source view with a per-line U/R/A column,
#   - append a reachability tally + actionable list to summary.txt.
#
# Primary assertions run against synthetic llvm-cov-shaped fixtures (toolchain
# free). A clang-gated section then repeats end-to-end against real `llvm-cov
# show` output to guard against format drift.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
COV="$(pwd)/cov-analysis"

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not available"; exit 0; }

source ./cov-analysis

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)

# 4 functions at known line ranges (3 lines each, blank line between).
SRC=(
"int covered_fn(int x) {"        # L1  covered, reachable
"  return x + 1;"                # L2
"}"                              # L3
""                               # L4
"int reachable_unreached(int x) {"  # L5 uncovered, reachable (medium confidence, indirect_only)
"  return x - 1;"                # L6
"}"                              # L7
""                               # L8
"int dead_fn(int x) {"           # L9  uncovered, unreachable
"  return x * 2;"                # L10
"}"                              # L11
""                               # L12
"int anomaly_fn(int x) {"        # L13 covered yet unreachable (anomaly)
"  return x / 2;"                # L14
"}"                              # L15
)

# ── coverage.json (llvm-cov export shape) ────────────────────────────────────
cat > "$TMP/coverage.json" << EOF
{ "data": [ { "files": [ { "filename": "$TMP/foo.c", "segments": [], "summary": {} } ],
  "functions": [
    { "name": "covered_fn",          "count": 5, "filenames": ["$TMP/foo.c"], "regions": [[1,1,3,2,5,0,0,0]] },
    { "name": "reachable_unreached", "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[5,1,7,2,0,0,0,0]] },
    { "name": "dead_fn",             "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[9,1,11,2,0,0,0,0]] },
    { "name": "anomaly_fn",          "count": 3, "filenames": ["$TMP/foo.c"], "regions": [[13,1,15,2,3,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF

# ── reachability JSON: reachable (one indirect-only, medium confidence) +
# unreachable_defined ─────────────────────────────────────────────────────────
cat > "$TMP/reach.json" << 'EOF'
{ "reachable": [
    { "mangled": "covered_fn",          "file": "foo.c", "line": 1, "indirect_only": false, "confidence": "high" },
    { "mangled": "reachable_unreached", "file": "foo.c", "line": 5, "indirect_only": true, "confidence": "medium" } ],
  "unreachable_defined": [
    { "mangled": "dead_fn",    "file": "foo.c", "line": 9 },
    { "mangled": "anomaly_fn", "file": "foo.c", "line": 13 } ] }
EOF

# ── synthetic llvm-cov HTML output (index + per-file + style.css) ─────────────
mkdir -p "$TMP/html/coverage" "$TMP/text/coverage"
printf "/* base */\n" > "$TMP/html/style.css"
# Flat index.html (as llvm-cov emits without -show-directory-coverage): a file
# row + Totals row, columns Function/Line/Region/Branch. Original numbers here
# are placeholders the annotator must overwrite with reachable-only figures.
{
  printf "%s" "<!doctype html><html><head></head><body><h2>Coverage Report</h2><div class='centered'><table>"
  printf "%s" "<tr><td class='column-entry-bold'>Filename</td><td class='column-entry-bold'>Function Coverage</td><td class='column-entry-bold'>Line Coverage</td><td class='column-entry-bold'>Region Coverage</td><td class='column-entry-bold'>Branch Coverage</td></tr>"
  printf "%s" "<tr class='light-row'><td><pre><a href='coverage${TMP}/foo.c.html'>${TMP}/foo.c</a></pre></td><td class='column-entry-red'><pre>  50.00% (2/4)</pre></td><td class='column-entry-red'><pre>  50.00% (6/12)</pre></td><td class='column-entry-red'><pre>  43.75% (7/16)</pre></td><td class='column-entry-gray'><pre>- (0/0)</pre></td></tr>"
  printf "%s" "<tr class='light-row-bold'><td><pre>Totals</pre></td><td class='column-entry-red'><pre>  50.00% (2/4)</pre></td><td class='column-entry-red'><pre>  50.00% (6/12)</pre></td><td class='column-entry-red'><pre>  43.75% (7/16)</pre></td><td class='column-entry-gray'><pre>- (0/0)</pre></td></tr>"
  printf "%s\n" "</table></div></body></html>"
} > "$TMP/html/index.html"

HFILE="$TMP/html/coverage/foo.c.html"
{
  printf "%s" "<!doctype html><html><head><link rel='stylesheet' type='text/css' href='../../style.css'></head><body><h2>Coverage Report</h2><div class='centered'><table><div class='source-name-title'><pre>$TMP/foo.c</pre></div>"
  printf "\n<tr><td><pre>Line</pre></td><td><pre>Count</pre></td><td><pre>Source</pre></td></tr>"
  for i in "${!SRC[@]}"; do
    ln=$((i + 1))
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='covered-line'><pre>1</pre></td><td class='code'><pre>%s</pre></td></tr>" "$ln" "$ln" "$ln" "${SRC[$i]}"
  done
  printf "\n</table></div></body></html>\n"
} > "$HFILE"

# ── synthetic llvm-cov text output ───────────────────────────────────────────
TFILE="$TMP/text/coverage/foo.c.txt"
{
  printf "Coverage Report\n"
  printf "Created: 2026\n"
  printf "%s:\n" "$TMP/foo.c"
  for i in "${!SRC[@]}"; do
    ln=$((i + 1))
    printf "%5d|%7d|%s\n" "$ln" 1 "${SRC[$i]}"
  done
} > "$TFILE"

# ── summary.txt (as llvm-cov report would leave it) ──────────────────────────
printf "Filename  Regions  Missed  Cover\nTOTAL  10  4  60.00%%\n" > "$TMP/summary.txt"

# ── per-function metrics (as `llvm-cov report -show-functions` emits) ────────
# covered_fn (reachable, executed), reachable_unreached (reachable, 0),
# dead_fn (unreachable, 0), anomaly_fn (unreachable but executed). Excluding the
# two unreachable functions leaves: Functions 1/2, Lines 3/6, Regions 3/8,
# Branches 1/4.
cat > "$TMP/perfunc.txt" << EOF
File '$TMP/foo.c':
Name                 Regions  Miss  Cover    Lines  Miss  Cover    Branches  Miss  Cover
covered_fn               4     1   75.00%      3     0  100.00%        2     1   50.00%
reachable_unreached      4     4    0.00%      3     3    0.00%        2     2    0.00%
dead_fn                  4     4    0.00%      3     3    0.00%        2     2    0.00%
anomaly_fn               4     0  100.00%      3     0  100.00%        2     0  100.00%
TOTAL                   16     9   43.75%     12     6   50.00%        8     5   37.50%
EOF

# ── run the annotator (6th arg = per-function report → recompute numbers) ────
TALLY="$(annotate_reachability "$TMP/coverage.json" "$TMP/reach.json" \
  "$TMP/html" "$TMP/text" "$TMP/summary.txt" "$TMP/perfunc.txt")" \
  || die "annotate_reachability returned non-zero"

# HTML file view: unreachable grey, reachable-unreached (indirect) amber,
# anomaly purple, covered untouched.
grep -q "reach-grey'><td class='line-number'><a name='L9'" "$HFILE" \
  || die "html: dead_fn line should get class reach-grey"
grep -q "reach-amber-indirect'><td class='line-number'><a name='L5'" "$HFILE" \
  || die "html: reachable_unreached (indirect) line should get reach-amber-indirect"
grep -q "reach-anomaly'><td class='line-number'><a name='L13'" "$HFILE" \
  || die "html: anomaly_fn line should get reach-anomaly"
grep -q "<tr><td class='line-number'><a name='L1'" "$HFILE" \
  || die "html: covered_fn line must stay untouched (plain <tr>)"
echo "[PASS] html file-view tinting"

# CSS rules appended once to the shared stylesheet.
grep -q 'reach-grey' "$TMP/html/style.css" \
  || die "style.css should gain the reachability CSS rules"
echo "[PASS] style.css rules"

# index.html banner with the tally.
grep -qi 'reachab' "$TMP/html/index.html" \
  || die "index.html should gain a reachability banner"
grep -q 'not yet reached' "$TMP/html/index.html" \
  || die "index.html banner should report the not-yet-reached count"
echo "[PASS] index.html banner"

# Text source view: U/R/A marker column + legend, covered stays blank.
grep -Eq '^ *9\|[^|]*\|U ' "$TFILE"  || die "text: dead_fn line should be marked U"
grep -Eq '^ *5\|[^|]*\|R ' "$TFILE"  || die "text: reachable_unreached line should be marked R"
grep -Eq '^ *13\|[^|]*\|A ' "$TFILE" || die "text: anomaly_fn line should be marked A"
grep -Eq '^ *1\|[^|]*\|  int covered_fn' "$TFILE" || die "text: covered_fn line must stay unmarked"
grep -q 'U=unreachable' "$TFILE" || die "text: should carry a reachability legend"
echo "[PASS] text marker column"

# summary.txt block.
grep -q 'Reachable but NOT reached' "$TMP/summary.txt" || die "summary.txt should list actionable functions"
grep -q 'reachable_unreached' "$TMP/summary.txt"       || die "summary.txt should name the actionable function"
grep -qi 'unreachable functions' "$TMP/summary.txt"    || die "summary.txt should count unreachable functions"
echo "[PASS] summary.txt block"

# summary.txt: reachable-only coverage table, excluding the 2 unreachable funcs.
grep -qi 'Reachable-only coverage' "$TMP/summary.txt" || die "summary.txt should carry the reachable-only table"
grep -q '1/2' "$TMP/summary.txt"  || die "summary.txt: functions should be 1/2 (dead+anomaly excluded)"
grep -q '3/8' "$TMP/summary.txt"  || die "summary.txt: regions should be 3/8"
grep -q '3/6' "$TMP/summary.txt"  || die "summary.txt: lines should be 3/6"
grep -q '1/4' "$TMP/summary.txt"  || die "summary.txt: branches should be 1/4"
echo "[PASS] summary.txt reachable-only numbers"

# index.html: file + Totals cells patched to the reachable-only figures.
grep -q '(1/2)' "$TMP/html/index.html" || die "index.html: function cell should become (1/2)"
grep -q '(3/6)' "$TMP/html/index.html" || die "index.html: line cell should become (3/6)"
grep -q '(3/8)' "$TMP/html/index.html" || die "index.html: region cell should become (3/8)"
grep -q '(1/4)' "$TMP/html/index.html" || die "index.html: branch cell should become (1/4)"
grep -q '(2/4)' "$TMP/html/index.html" && die "index.html: stale original (2/4) must be overwritten"
echo "[PASS] index.html cells patched"

# Tally on stdout.
printf '%s\n' "$TALLY" | grep -q 'unreachable=2' || die "tally should report unreachable=2 (got: $TALLY)"
echo "[PASS] stdout tally"

# ── dir-mode (reached.txt / not_reached.txt) still classifies ────────────────
mkdir -p "$TMP/lists"
printf '# SanitizerCoverage allowlist\nsrc:*\nfun:covered_fn\nfun:reachable_unreached\n' > "$TMP/lists/reached.txt"
printf '# SanitizerCoverage ignorelist\nfun:dead_fn\nfun:anomaly_fn\n' > "$TMP/lists/not_reached.txt"
# fresh copies so the in-place edits start clean
rm -rf "$TMP/html2" "$TMP/text2"; cp -r "$TMP/html" "$TMP/html2"; cp -r "$TMP/text" "$TMP/text2"
# strip prior edits from the copies' source pages
printf "%s" "<!doctype html><html><head><link rel='stylesheet' type='text/css' href='../../style.css'></head><body><div class='centered'><table><div class='source-name-title'><pre>$TMP/foo.c</pre></div>" > "$TMP/html2/coverage/foo.c.html"
{
  for i in "${!SRC[@]}"; do
    ln=$((i + 1))
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>%s</pre></td></tr>" "$ln" "$ln" "$ln" "${SRC[$i]}"
  done
  printf "\n</table></div></body></html>\n"
} >> "$TMP/html2/coverage/foo.c.html"
cp "$TMP/html/style.css" "$TMP/html2/style.css"
printf "Coverage Report\n%s:\n" "$TMP/foo.c" > "$TMP/text2/coverage/foo.c.txt"
for i in "${!SRC[@]}"; do ln=$((i + 1)); printf "%5d|%7d|%s\n" "$ln" 1 "${SRC[$i]}" >> "$TMP/text2/coverage/foo.c.txt"; done
cp "$TMP/summary.txt" "$TMP/summary2.txt"
annotate_reachability "$TMP/coverage.json" "$TMP/lists" "$TMP/html2" "$TMP/text2" "$TMP/summary2.txt" >/dev/null \
  || die "annotate_reachability (dir mode) returned non-zero"
# txt lists carry no confidence info → plain amber
grep -q "reach-amber'><td class='line-number'><a name='L5'" "$TMP/html2/coverage/foo.c.html" \
  || die "dir-mode: reachable_unreached should be plain reach-amber"
grep -q "reach-grey'><td class='line-number'><a name='L9'" "$TMP/html2/coverage/foo.c.html" \
  || die "dir-mode: dead_fn should be reach-grey"
echo "[PASS] dir-mode (txt lists)"

# ── confidence grades the amber shade: low/medium/high must land in three
# DISTINCT classes, and a JSON-mode function with no confidence field must
# default to the same plain reach-amber as 'high' (matching dir-mode above,
# which has no confidence data at all). ────────────────────────────────────
mkdir -p "$TMP/confgrade"
FILE_CG="$TMP/confgrade/lib.c"
cat > "$TMP/confgrade_reach.json" << EOF
{ "reachable": [
    { "mangled": "low_fn",    "file": "$FILE_CG", "line": 1,  "indirect_only": true,  "confidence": "low" },
    { "mangled": "medium_fn", "file": "$FILE_CG", "line": 5,  "indirect_only": true,  "confidence": "medium" },
    { "mangled": "high_fn",   "file": "$FILE_CG", "line": 9,  "indirect_only": false, "confidence": "high" },
    { "mangled": "noconf_fn", "file": "$FILE_CG", "line": 13, "indirect_only": false } ],
  "unreachable_defined": [] }
EOF
cat > "$TMP/confgrade_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "low_fn",    "count": 0, "filenames": ["$FILE_CG"], "regions": [[1,1,3,2,0,0,0,0]] },
    { "name": "medium_fn", "count": 0, "filenames": ["$FILE_CG"], "regions": [[5,1,7,2,0,0,0,0]] },
    { "name": "high_fn",   "count": 0, "filenames": ["$FILE_CG"], "regions": [[9,1,11,2,0,0,0,0]] },
    { "name": "noconf_fn", "count": 0, "filenames": ["$FILE_CG"], "regions": [[13,1,15,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/confgrade_html/coverage" "$TMP/confgrade_text/coverage"
printf "/* base */\n" > "$TMP/confgrade_html/style.css"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$FILE_CG</pre></div>"
  for ln in $(seq 1 15); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/confgrade_html/coverage/lib.c.html"
{
  printf "Coverage Report\n%s:\n" "$FILE_CG"
  for ln in $(seq 1 15); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
} > "$TMP/confgrade_text/coverage/lib.c.txt"
: > "$TMP/confgrade_summary.txt"
annotate_reachability "$TMP/confgrade_coverage.json" "$TMP/confgrade_reach.json" \
  "$TMP/confgrade_html" "$TMP/confgrade_text" "$TMP/confgrade_summary.txt" >/dev/null \
  || die "confgrade: annotate_reachability returned non-zero"

CGHTML="$TMP/confgrade_html/coverage/lib.c.html"
# Positive: each confidence level lands in its own class.
grep -q "reach-amber-low'><td class='line-number'><a name='L1'" "$CGHTML" \
  || die "confgrade: low-confidence function should classify reach-amber-low"
grep -q "reach-amber-indirect'><td class='line-number'><a name='L5'" "$CGHTML" \
  || die "confgrade: medium-confidence function should classify reach-amber-indirect"
grep -q "reach-amber'><td class='line-number'><a name='L9'" "$CGHTML" \
  || die "confgrade: high-confidence function should classify plain reach-amber"
grep -q "reach-amber'><td class='line-number'><a name='L13'" "$CGHTML" \
  || die "confgrade: absent-confidence function should default to plain reach-amber"
# Negative: none of the three collapse into one another.
grep -q "reach-amber-indirect'><td class='line-number'><a name='L1'" "$CGHTML" \
  && die "confgrade: low must NOT collapse into reach-amber-indirect"
grep -q "reach-amber'><td class='line-number'><a name='L1'" "$CGHTML" \
  && die "confgrade: low must NOT collapse into plain reach-amber"
grep -q "reach-amber-low'><td class='line-number'><a name='L5'" "$CGHTML" \
  && die "confgrade: medium must NOT collapse into reach-amber-low"
grep -q "reach-amber'><td class='line-number'><a name='L5'" "$CGHTML" \
  && die "confgrade: medium must NOT collapse into plain reach-amber"
grep -q "reach-amber-low'><td class='line-number'><a name='L9'" "$CGHTML" \
  && die "confgrade: high must NOT collapse into reach-amber-low"
grep -q "reach-amber-indirect'><td class='line-number'><a name='L9'" "$CGHTML" \
  && die "confgrade: high must NOT collapse into reach-amber-indirect"
echo "[PASS] confgrade: low/medium/high confidence classify into 3 distinct amber shades, absent defaults to high"

# Text marker column stays 'R' for every confidence grade — only the HTML
# shade differs, not the U/R/A taxonomy.
CGTEXT="$TMP/confgrade_text/coverage/lib.c.txt"
grep -Eq '^ *1\|[^|]*\|R ' "$CGTEXT" || die "confgrade: low-confidence text marker should stay R"
grep -Eq '^ *5\|[^|]*\|R ' "$CGTEXT" || die "confgrade: medium-confidence text marker should stay R"
grep -Eq '^ *9\|[^|]*\|R ' "$CGTEXT" || die "confgrade: high-confidence text marker should stay R"
echo "[PASS] confgrade: text marker column stays R regardless of confidence shade"

# style.css must gain the new lightest-amber rule alongside the existing ones.
grep -q 'reach-amber-low' "$TMP/confgrade_html/style.css" \
  || die "confgrade: style.css should gain the reach-amber-low CSS rule"
echo "[PASS] confgrade: style.css carries the reach-amber-low rule"

# ── diff --reachability still splits still-uncovered functions ───────────────
cp "$TMP/coverage.json" "$TMP/new.json"
cat > "$TMP/old.json" << EOF
{ "data": [ { "files": [ { "filename": "$TMP/foo.c", "segments": [], "summary": {} } ],
  "functions": [
    { "name": "covered_fn",          "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[1,1,3,2,0,0,0,0]] },
    { "name": "reachable_unreached", "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[5,1,7,2,0,0,0,0]] },
    { "name": "dead_fn",             "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[9,1,11,2,0,0,0,0]] },
    { "name": "anomaly_fn",          "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[13,1,15,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
bash "$COV" diff --reachability "$TMP/reach.json" -o "$TMP" "$TMP/old.json" "$TMP/new.json" \
  || die "diff --reachability returned non-zero"
grep -q 'chip-amber">reachable_unreached<' "$TMP/coverage_diff.html" \
  || die "diff: reachable_unreached should render as an amber chip"
grep -q 'chip-grey">dead_fn<' "$TMP/coverage_diff.html" \
  || die "diff: dead_fn should render as a grey chip"
echo "[PASS] diff --reachability"

grep -Eq "reach-amber(-indirect)?'><td class='line-number'><a name='L5'" "$HFILE" \
  || die "parity: report path must classify reachable_unreached as reachable"
grep -q 'chip-amber">reachable_unreached<' "$TMP/coverage_diff.html" \
  || die "parity: diff path must classify reachable_unreached as reachable, matching the report path"
echo "[PASS] report/diff parity: reachable_unreached classified reachable in both paths"

# ── report/diff parity: Rust generic hash mismatch must classify the same way
# in both the `report` (annotate_reachability) and `diff` (cmd_diff) code
# paths. The reachability tool records one hash for a monomorphized generic
# (17h...E disambiguator); llvm-cov's own symbol for the same function can
# carry a different hash from a different codegen unit. Using an
# unreachable_defined entry here (rather than reachable) gives an
# unambiguous signal: without the key fallback the name match misses and the
# function falls through to the default "not in reachability set" bucket
# (rendered amber, same as a genuinely-reachable miss) instead of the
# dead/unreachable bucket (grey) — so a wrong classification is distinguishable
# from a correct one, not just a differently-labelled amber chip.
RUST_UNREACH_NAME='_ZN7testlib7genfunc17h1111111111111111E'
RUST_COV_NAME='_ZN7testlib7genfunc17h2222222222222222E'
cat > "$TMP/rust_reach.json" << EOF
{ "reachable": [],
  "unreachable_defined": [ { "mangled": "$RUST_UNREACH_NAME" } ] }
EOF
cat > "$TMP/rust_coverage.json" << EOF
{ "data": [ { "files": [ { "filename": "$TMP/rust.rs", "segments": [], "summary": {} } ],
  "functions": [
    { "name": "$RUST_COV_NAME", "count": 0, "filenames": ["$TMP/rust.rs"], "regions": [[1,1,3,2,0,0,0,0]] },
    { "name": "helper_fn",      "count": 5, "filenames": ["$TMP/rust.rs"], "regions": [[5,1,7,2,5,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF

# report path: annotate_reachability must tint the function reach-grey
# (unreachable) even though the hashes differ.
mkdir -p "$TMP/rust_html/coverage" "$TMP/rust_text"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$TMP/rust.rs</pre></div>"
  printf "\n<tr><td class='line-number'><a name='L1' href='#L1'><pre>1</pre></a></td><td class='code'><pre>fn genfunc() {}</pre></td></tr>"
  printf "\n</table></div></body></html>\n"
} > "$TMP/rust_html/coverage/rust.rs.html"
annotate_reachability "$TMP/rust_coverage.json" "$TMP/rust_reach.json" "$TMP/rust_html" "$TMP/rust_text" "$TMP/rust_summary.txt" >/dev/null \
  || die "parity: annotate_reachability returned non-zero on hash-mismatched Rust generic"
grep -q "reach-grey'>" "$TMP/rust_html/coverage/rust.rs.html" \
  || die "parity: report path should classify the hash-mismatched generic as unreachable (reach-grey)"
echo "[PASS] report path: Rust generic hash-key fallback"

# diff path: same reachability input, genfunc still-uncovered in both old and
# new coverage while helper_fn becomes newly covered →
# genfunc must land in the grey (unreachable) chip group, not the default
# amber "not in reachability set" bucket.
cat > "$TMP/rust_old.json" << EOF
{ "data": [ { "files": [ { "filename": "$TMP/rust.rs", "segments": [], "summary": {} } ],
  "functions": [
    { "name": "$RUST_COV_NAME", "count": 0, "filenames": ["$TMP/rust.rs"], "regions": [[1,1,3,2,0,0,0,0]] },
    { "name": "helper_fn",      "count": 0, "filenames": ["$TMP/rust.rs"], "regions": [[5,1,7,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
bash "$COV" diff --reachability "$TMP/rust_reach.json" -o "$TMP/rust_diff" "$TMP/rust_old.json" "$TMP/rust_coverage.json" \
  || die "parity: diff --reachability returned non-zero on hash-mismatched Rust generic"
grep -q "chip-grey\">$RUST_COV_NAME<" "$TMP/rust_diff/coverage_diff.html" \
  || die "parity: diff path should classify the hash-mismatched generic as unreachable (chip-grey), matching the report path"
grep -q "chip-amber\">$RUST_COV_NAME<" "$TMP/rust_diff/coverage_diff.html" \
  && die "parity: diff path must not fall back to the default amber bucket for the hash-mismatched generic"
echo "[PASS] diff path agrees with report path on Rust generic hash-key fallback"

# ── classify states (not just parity): hash-mismatched Rust generics must
# land in the correct bucket. The coverage binary's own codegen unit mangles
# each generic instance with a different 17h<hash> disambiguator than the one
# the reachability tool recorded, but the shared join `key` must still
# classify the reachable instance 'reachable-unreached' (amber) and the
# unreachable one 'unreachable' (grey) — never falling through to 'unknown'
# (which would leave the line untouched and unmarked).
REACHJSON="$TMP/reach_rust.json"
cat > "$REACHJSON" <<'JSON'
{"reachable":[{"mangled":"_ZN3app4work17haaaaaaaaaaaaaaaaE","key":"_ZN3app4work","indirect_only":false,"file":null,"line":null}],
 "unreachable_defined":[{"mangled":"_ZN3app4dead17hccccccccccccccccE","key":"_ZN3app4dead","file":null,"line":null}]}
JSON
COVJSON="$TMP/cov_rust.json"
cat > "$COVJSON" <<'JSON'
{"data":[{"functions":[
  {"name":"_ZN3app4work17hbbbbbbbbbbbbbbbbE","count":0,"filenames":["app.rs"],"regions":[[5,1,7,2,0,0,0,0]]},
  {"name":"_ZN3app4dead17hddddddddddddddddE","count":0,"filenames":["app.rs"],"regions":[[9,1,11,2,0,0,0,0]]}]}]}
JSON

# Minimal html/text fixtures spanning lines 1-11 so the L5/L9 anchors exist,
# same shape the main block above already relies on.
mkdir -p "$TMP/rust2_html/coverage" "$TMP/rust2_text/coverage"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>app.rs</pre></div>"
  for ln in $(seq 1 11); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/rust2_html/coverage/app.rs.html"
{
  printf "Coverage Report\napp.rs:\n"
  for ln in $(seq 1 11); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
} > "$TMP/rust2_text/coverage/app.rs.txt"
: > "$TMP/rust2_summary.txt"

annotate_reachability "$COVJSON" "$REACHJSON" "$TMP/rust2_html" "$TMP/rust2_text" "$TMP/rust2_summary.txt" >/dev/null \
  || die "classify: annotate_reachability returned non-zero on hash-mismatched Rust generics"

grep -q "reach-amber'><td class='line-number'><a name='L5'" "$TMP/rust2_html/coverage/app.rs.html" \
  || die "classify: hash-mismatched reachable generic should classify reachable-unreached (reach-amber), not unknown"
grep -q "reach-grey'><td class='line-number'><a name='L9'" "$TMP/rust2_html/coverage/app.rs.html" \
  || die "classify: hash-mismatched unreachable generic should classify unreachable (reach-grey), not unknown"
grep -Eq '^ *5\|[^|]*\|R ' "$TMP/rust2_text/coverage/app.rs.txt" \
  || die "classify: text view should mark the reachable-unreached line R"
grep -Eq '^ *9\|[^|]*\|U ' "$TMP/rust2_text/coverage/app.rs.txt" \
  || die "classify: text view should mark the unreachable line U"
grep -q '_ZN3app4work17hbbbbbbbbbbbbbbbbE' "$TMP/rust2_summary.txt" \
  || die "classify: summary.txt actionable list should name the coverage-side hash-mismatched function"
grep -Eq '^ *reachable functions +: 1$' "$TMP/rust2_summary.txt" \
  || die "classify: summary.txt should count exactly 1 reachable function"
grep -Eq 'unreachable functions +: 1' "$TMP/rust2_summary.txt" \
  || die "classify: summary.txt should count exactly 1 unreachable function"
echo "[PASS] classify: Rust generic hash-key fallback yields reachable-unreached / unreachable, not unknown"

# ── full-path collision fix: same basename+line, different directories ──────
mkdir -p "$TMP/collide/dirA" "$TMP/collide/dirB"
FILE_A="$TMP/collide/dirA/mod.c"
FILE_B="$TMP/collide/dirB/mod.c"
cat > "$TMP/collide_reach.json" << EOF
{ "reachable": [ { "mangled": "recorded_fn_a", "file": "$FILE_A", "line": 10 } ],
  "unreachable_defined": [ { "mangled": "recorded_fn_b", "file": "$FILE_B", "line": 10 } ] }
EOF
cat > "$TMP/collide_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "observed_fn_a", "count": 0, "filenames": ["$FILE_A"], "regions": [[10,1,12,2,0,0,0,0]] },
    { "name": "observed_fn_b", "count": 0, "filenames": ["$FILE_B"], "regions": [[10,1,12,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/collide_html/coverage" "$TMP/collide_text/coverage"
for f in A B; do
  fv="FILE_$f"; fpath="${!fv}"
  {
    printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$fpath</pre></div>"
    for ln in $(seq 1 12); do
      printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
    done
    printf "\n</table></div></body></html>\n"
  } > "$TMP/collide_html/coverage/mod_$f.html"
  {
    printf "Coverage Report\n%s:\n" "$fpath"
    for ln in $(seq 1 12); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
  } > "$TMP/collide_text/coverage/mod_$f.txt"
done
: > "$TMP/collide_summary.txt"
annotate_reachability "$TMP/collide_coverage.json" "$TMP/collide_reach.json" \
  "$TMP/collide_html" "$TMP/collide_text" "$TMP/collide_summary.txt" >/dev/null \
  || die "collision: annotate_reachability returned non-zero"
grep -q "reach-amber'><td class='line-number'><a name='L10'" "$TMP/collide_html/coverage/mod_A.html" \
  || die "collision: dirA/mod.c (reachable) line 10 should classify reach-amber via its own full-path fallback"
grep -q "reach-grey'><td class='line-number'><a name='L10'" "$TMP/collide_html/coverage/mod_B.html" \
  || die "collision: dirB/mod.c (unreachable) line 10 should classify reach-grey via its own full-path fallback, not inherit dirA's basename-collided state"
echo "[PASS] full-path (basename,line) collision fix: same basename+line in different directories classify independently"

# ── static-name collision fix: same symbol name, different files ────────────
mkdir -p "$TMP/qualify"
FILE_C="$TMP/qualify/a.c"
FILE_D="$TMP/qualify/b.c"
cat > "$TMP/qualify_reach.json" << EOF
{ "reachable": [ { "mangled": "helper", "file": "$FILE_C" } ],
  "unreachable_defined": [ { "mangled": "helper", "file": "$FILE_D" } ] }
EOF
cat > "$TMP/qualify_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "$FILE_C:helper", "count": 0, "filenames": ["$FILE_C"], "regions": [[3,1,5,2,0,0,0,0]] },
    { "name": "$FILE_D:helper", "count": 0, "filenames": ["$FILE_D"], "regions": [[3,1,5,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/qualify_html/coverage" "$TMP/qualify_text/coverage"
for f in C D; do
  fv="FILE_$f"; fpath="${!fv}"
  {
    printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$fpath</pre></div>"
    for ln in $(seq 1 5); do
      printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
    done
    printf "\n</table></div></body></html>\n"
  } > "$TMP/qualify_html/coverage/${f}.html"
  {
    printf "Coverage Report\n%s:\n" "$fpath"
    for ln in $(seq 1 5); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
  } > "$TMP/qualify_text/coverage/${f}.txt"
done
: > "$TMP/qualify_summary.txt"
annotate_reachability "$TMP/qualify_coverage.json" "$TMP/qualify_reach.json" \
  "$TMP/qualify_html" "$TMP/qualify_text" "$TMP/qualify_summary.txt" >/dev/null \
  || die "qualify: annotate_reachability returned non-zero"
grep -q "reach-amber'><td class='line-number'><a name='L3'" "$TMP/qualify_html/coverage/C.html" \
  || die "qualify: a.c:helper (reachable) should classify reach-amber via the file-qualified match"
grep -q "reach-grey'><td class='line-number'><a name='L3'" "$TMP/qualify_html/coverage/D.html" \
  || die "qualify: b.c:helper (unreachable) should classify reach-grey via its own file-qualified match, not inherit a.c's bare-tail-matched state"
echo "[PASS] static-name (file:sym) collision fix: same symbol in different files classify by their own file"

# ── F2: v0-mangled coverage name joins via the hardened full-path (file,line) fallback ──
FILE_E="$TMP/rustv0/lib.rs"
mkdir -p "$TMP/rustv0"
V0_NAME='_RINvCs1a2b3c4d5e6f_3app4workE'
LEGACY_NAME='_ZN3app4work17h1111111111111111E'
cat > "$TMP/v0_reach.json" << EOF
{ "reachable": [ { "mangled": "$LEGACY_NAME", "file": "$FILE_E", "line": 20 } ],
  "unreachable_defined": [] }
EOF
cat > "$TMP/v0_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "$V0_NAME", "count": 0, "filenames": ["$FILE_E"], "regions": [[20,1,22,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/v0_html/coverage" "$TMP/v0_text/coverage"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$FILE_E</pre></div>"
  for ln in $(seq 1 22); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/v0_html/coverage/lib.rs.html"
{
  printf "Coverage Report\n%s:\n" "$FILE_E"
  for ln in $(seq 1 22); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
} > "$TMP/v0_text/coverage/lib.rs.txt"
: > "$TMP/v0_summary.txt"
python3 -c "
import re
d = re.compile(r'17h[0-9a-f]{16}E\$')
assert d.sub('', '$V0_NAME') == '$V0_NAME', 'test setup bug: v0 name must be untouched by the legacy disambiguator regex'
" || die "F2 test setup: v0 name must not match _reach_key's legacy regex"
annotate_reachability "$TMP/v0_coverage.json" "$TMP/v0_reach.json" \
  "$TMP/v0_html" "$TMP/v0_text" "$TMP/v0_summary.txt" >/dev/null \
  || die "F2: annotate_reachability returned non-zero"
grep -q "reach-amber'><td class='line-number'><a name='L20'" "$TMP/v0_html/coverage/lib.rs.html" \
  || die "F2: v0-mangled coverage name should still classify reach-amber via the full-path (file,line) fallback"
echo "[PASS] F2: v0-mangled coverage name joins via the hardened full-path (file,line) fallback"

# ── F2b: a v0-mangled coverage name that is UNREACHABLE only via the
# (file,line) fallback must be excluded from BOTH the tally count AND the
# parse_perfunc recompute (reachable-only Function/Line/Region/Branch
# denominators). reach_member (used by parse_perfunc) only does exact+key
# matching and misses this join, so before the fix the tally correctly says
# "unreachable: 1" while the recompute still counts the dead function in ──
FILE_I="$TMP/rustv0dead/lib.rs"
mkdir -p "$TMP/rustv0dead"
V0_NAME_DEAD='_RINvCs9z8y7x6w5v_3app4deadE'
LEGACY_NAME_DEAD='_ZN3app4dead17h3333333333333333E'
cat > "$TMP/v0dead_reach.json" << EOF
{ "reachable": [ { "mangled": "keep_fn", "file": "$FILE_I", "line": 1 } ],
  "unreachable_defined": [ { "mangled": "$LEGACY_NAME_DEAD", "file": "$FILE_I", "line": 20 } ] }
EOF
cat > "$TMP/v0dead_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "keep_fn",       "count": 5, "filenames": ["$FILE_I"], "regions": [[1,1,3,2,5,0,0,0]] },
    { "name": "$V0_NAME_DEAD", "count": 0, "filenames": ["$FILE_I"], "regions": [[20,1,22,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
python3 -c "
import re
d = re.compile(r'17h[0-9a-f]{16}E\$')
assert d.sub('', '$V0_NAME_DEAD') == '$V0_NAME_DEAD', 'test setup bug: v0 name must be untouched by the legacy disambiguator regex'
" || die "F2b test setup: v0 name must not match _reach_key's legacy regex"
mkdir -p "$TMP/v0dead_html/coverage" "$TMP/v0dead_text/coverage"
: > "$TMP/v0dead_summary.txt"
cat > "$TMP/v0dead_perfunc.txt" << EOF
File '$FILE_I':
Name                 Regions  Miss  Cover    Lines  Miss  Cover    Branches  Miss  Cover
keep_fn                  4     1   75.00%      3     0  100.00%        3     1   66.67%
$V0_NAME_DEAD            4     4    0.00%      3     3    0.00%        3     3    0.00%
TOTAL                    8     5   37.50%      6     3   50.00%        6     4   33.33%
EOF
annotate_reachability "$TMP/v0dead_coverage.json" "$TMP/v0dead_reach.json" \
  "$TMP/v0dead_html" "$TMP/v0dead_text" "$TMP/v0dead_summary.txt" "$TMP/v0dead_perfunc.txt" >/dev/null \
  || die "F2b: annotate_reachability returned non-zero"
# tally: the v0-mangled function is unreachable only via the (file,line) fallback.
grep -Eq 'unreachable functions +: 1' "$TMP/v0dead_summary.txt" \
  || die "F2b: tally should count the (file,line)-joined function as unreachable"
# recompute must agree with the tally: keep_fn alone (the dead function's
# metrics must not leak into the reachable-only denominators).
grep -q '(1/1)' "$TMP/v0dead_summary.txt" \
  || die "F2b: reachable-only Functions should be 1/1 (dead function excluded, matching the tally)"
grep -q '(3/3)' "$TMP/v0dead_summary.txt" \
  || die "F2b: reachable-only Lines should be 3/3"
grep -q '(3/4)' "$TMP/v0dead_summary.txt" \
  || die "F2b: reachable-only Regions should be 3/4"
grep -q '(2/3)' "$TMP/v0dead_summary.txt" \
  || die "F2b: reachable-only Branches should be 2/3"
grep -q '(1/2)' "$TMP/v0dead_summary.txt" \
  && die "F2b: pre-fix over-counted Functions figure (1/2) must not leak into the recompute"
grep -q '(3/6)' "$TMP/v0dead_summary.txt" \
  && die "F2b: pre-fix over-counted Lines figure (3/6) must not leak into the recompute"
grep -q '(3/8)' "$TMP/v0dead_summary.txt" \
  && die "F2b: pre-fix over-counted Regions figure (3/8) must not leak into the recompute"
grep -q '(2/6)' "$TMP/v0dead_summary.txt" \
  && die "F2b: pre-fix over-counted Branches figure (2/6) must not leak into the recompute"
echo "[PASS] F2b: (file,line)-only-joined unreachable function excluded from both the tally and the perfunc recompute"

# ── both name forms indexed: coverage emits the DEMANGLED name, reachability
# entry carries both mangled and demangled ──────────────────────────────────
FILE_F="$TMP/bothforms/lib.c"
mkdir -p "$TMP/bothforms"
MANGLED_NAME='_ZN3app6foobarEv'
DEMANGLED_NAME='app::foobar'
cat > "$TMP/bothforms_reach.json" << EOF
{ "reachable": [ { "mangled": "$MANGLED_NAME", "demangled": "$DEMANGLED_NAME", "file": null, "line": null, "indirect_only": false } ],
  "unreachable_defined": [] }
EOF
cat > "$TMP/bothforms_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "$DEMANGLED_NAME", "count": 0, "filenames": ["$FILE_F"], "regions": [[3,1,5,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/bothforms_html/coverage" "$TMP/bothforms_text/coverage"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$FILE_F</pre></div>"
  for ln in $(seq 1 5); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/bothforms_html/coverage/lib.c.html"
{
  printf "Coverage Report\n%s:\n" "$FILE_F"
  for ln in $(seq 1 5); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
} > "$TMP/bothforms_text/coverage/lib.c.txt"
: > "$TMP/bothforms_summary.txt"
annotate_reachability "$TMP/bothforms_coverage.json" "$TMP/bothforms_reach.json" \
  "$TMP/bothforms_html" "$TMP/bothforms_text" "$TMP/bothforms_summary.txt" >/dev/null \
  || die "bothforms: annotate_reachability returned non-zero"
grep -q "reach-amber'><td class='line-number'><a name='L3'" "$TMP/bothforms_html/coverage/lib.c.html" \
  || die "bothforms: a coverage function emitted under its DEMANGLED name should match a reachability entry carrying both mangled and demangled, and classify reach-amber"
echo "[PASS] both name forms indexed: demangled-named coverage function matches a mangled+demangled reachability entry"

# ── directory dispatch prefers a sibling reachability.json over the txt lists ─
mkdir -p "$TMP/dirjson"
FILE_G="$TMP/dirjson/mod.c"
cat > "$TMP/dirjson/reachability.json" << EOF
{ "reachable": [ { "mangled": "indirect_fn", "file": "$FILE_G", "line": 3, "indirect_only": true, "confidence": "medium" } ],
  "unreachable_defined": [] }
EOF
printf '# SanitizerCoverage allowlist\nfun:indirect_fn\n' > "$TMP/dirjson/reached.txt"
printf '# SanitizerCoverage ignorelist\n' > "$TMP/dirjson/not_reached.txt"
cat > "$TMP/dirjson_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "indirect_fn", "count": 0, "filenames": ["$FILE_G"], "regions": [[3,1,5,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/dirjson_html/coverage" "$TMP/dirjson_text/coverage"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$FILE_G</pre></div>"
  for ln in $(seq 1 5); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/dirjson_html/coverage/mod.c.html"
{
  printf "Coverage Report\n%s:\n" "$FILE_G"
  for ln in $(seq 1 5); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
} > "$TMP/dirjson_text/coverage/mod.c.txt"
: > "$TMP/dirjson_summary.txt"
DIRJSON_STDERR="$TMP/dirjson_stderr.txt"
annotate_reachability "$TMP/dirjson_coverage.json" "$TMP/dirjson" \
  "$TMP/dirjson_html" "$TMP/dirjson_text" "$TMP/dirjson_summary.txt" \
  >/dev/null 2>"$DIRJSON_STDERR" \
  || die "dir-prefers-json: annotate_reachability returned non-zero"
grep -q "reach-amber-indirect'><td class='line-number'><a name='L3'" "$TMP/dirjson_html/coverage/mod.c.html" \
  || die "dir-prefers-json: a directory containing reachability.json should use the JSON (medium confidence -> reach-amber-indirect), not silently fall back to the plain-amber txt lists"
grep -qi 'using reachability.json' "$DIRJSON_STDERR" \
  || die "dir-prefers-json: should log a one-line note that reachability.json is used over the txt lists"
echo "[PASS] directory dispatch prefers a sibling reachability.json over reached.txt/not_reached.txt"

# ── F1: a mangled expansion pseudo-header (llvm-cov's per-instantiation
# header for Rust generics, a mangled symbol ending in ':') must not reset
# the text-view marker state for the source lines that follow it ────────────
FILE_H="$TMP/pseudohdr/lib.rs"
mkdir -p "$TMP/pseudohdr"
cat > "$TMP/pseudohdr_reach.json" << EOF
{ "reachable": [ { "mangled": "work_fn", "file": "$FILE_H", "line": 1 } ],
  "unreachable_defined": [ { "mangled": "dead_fn", "file": "$FILE_H", "line": 9 } ] }
EOF
cat > "$TMP/pseudohdr_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "work_fn", "count": 0, "filenames": ["$FILE_H"], "regions": [[1,1,3,2,0,0,0,0]] },
    { "name": "dead_fn", "count": 0, "filenames": ["$FILE_H"], "regions": [[9,1,11,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/pseudohdr_html/coverage" "$TMP/pseudohdr_text/coverage"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$FILE_H</pre></div>"
  for ln in $(seq 1 11); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/pseudohdr_html/coverage/lib.rs.html"
TFILE_H="$TMP/pseudohdr_text/coverage/lib.rs.txt"
{
  printf "Coverage Report\n%s:\n" "$FILE_H"
  printf "%5d|%7d|fn work_fn() {\n" 1 0
  printf "%5d|%7d|  do_thing();\n" 2 0
  printf "%5d|%7d|}\n" 3 0
  # Rust per-instantiation expansion pseudo-header: a mangled symbol ending in
  # ':', not a source file — must not be mistaken for a new per-file header.
  printf "| _RINvCs1a2b3c4d5e6f_3app8work_fnE:\n"
  printf "%5d|%7d|fn dead_fn() {\n" 9 0
  printf "%5d|%7d|  do_dead();\n" 10 0
  printf "%5d|%7d|}\n" 11 0
} > "$TFILE_H"
: > "$TMP/pseudohdr_summary.txt"
annotate_reachability "$TMP/pseudohdr_coverage.json" "$TMP/pseudohdr_reach.json" \
  "$TMP/pseudohdr_html" "$TMP/pseudohdr_text" "$TMP/pseudohdr_summary.txt" >/dev/null \
  || die "F1: annotate_reachability returned non-zero"
grep -Eq '^ *1\|[^|]*\|R ' "$TFILE_H" \
  || die "F1: work_fn line 1 (reachable, before the pseudo-header) should be marked R"
grep -Eq '^ *9\|[^|]*\|U ' "$TFILE_H" \
  || die "F1: dead_fn line 9 (unreachable, AFTER the mangled expansion pseudo-header) should still be marked U"
grep -Eq '^ *10\|[^|]*\|U ' "$TFILE_H" \
  || die "F1: dead_fn line 10 (unreachable, AFTER the mangled expansion pseudo-header) should still be marked U"
echo "[PASS] F1: mangled expansion pseudo-header does not reset the text-view marker state"

# ── F3: perfunc recompute must disambiguate a static-name collision ─────────
# Two `static`-style functions share the bare name `helper` in different files:
# a.c:helper is reachable AND covered, b.c:helper is unreachable and uncovered.
# The reach_state tally classifies each correctly via the file-qualified layer
# (banner: 1 reachable, 1 unreachable). The `llvm-cov report -show-functions`
# perfunc report prints the BARE symbol `helper` under each `File '<path>':`
# section, so before the fix perfunc_member missed func_member_by_full and fell
# to func_member_by_norm[bare] (first-wins). With the unreachable copy first in
# the coverage JSON, that bare-name verdict is 'unreachable' → BOTH perfunc rows
# were excluded, DROPPING the live+covered a.c:helper from every reachable-only
# denominator (Functions 0/0 instead of 1/1). The fix keys perfunc_member on
# (basename(file), symbol), matching the tally's qualified layer.
mkdir -p "$TMP/perfcollide"
FILE_PA="$TMP/perfcollide/a.c"
FILE_PB="$TMP/perfcollide/b.c"
cat > "$TMP/perfcollide_reach.json" << EOF
{ "reachable": [ { "mangled": "helper", "file": "$FILE_PA", "line": 3 } ],
  "unreachable_defined": [ { "mangled": "helper", "file": "$FILE_PB", "line": 3 } ] }
EOF
# Unreachable copy FIRST so the first-wins bare-name map yields 'unreachable'
# and (pre-fix) drops the live one — the dangerous direction.
cat > "$TMP/perfcollide_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "$FILE_PB:helper", "count": 0, "filenames": ["$FILE_PB"], "regions": [[3,1,5,2,0,0,0,0]] },
    { "name": "$FILE_PA:helper", "count": 5, "filenames": ["$FILE_PA"], "regions": [[3,1,5,2,5,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/perfcollide_html/coverage" "$TMP/perfcollide_text/coverage"
for f in PA PB; do
  fv="FILE_$f"; fpath="${!fv}"
  {
    printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$fpath</pre></div>"
    for ln in $(seq 1 5); do
      printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
    done
    printf "\n</table></div></body></html>\n"
  } > "$TMP/perfcollide_html/coverage/${f}.html"
  {
    printf "Coverage Report\n%s:\n" "$fpath"
    for ln in $(seq 1 5); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
  } > "$TMP/perfcollide_text/coverage/${f}.txt"
done
: > "$TMP/perfcollide_summary.txt"
# Perfunc report: bare `helper` row under each File section (statics).
cat > "$TMP/perfcollide_perfunc.txt" << EOF
File '$FILE_PA':
Name       Regions  Miss  Cover    Lines  Miss  Cover    Branches  Miss  Cover
helper         4     1   75.00%      3     0  100.00%        2     1   50.00%
TOTAL          4     1   75.00%      3     0  100.00%        2     1   50.00%
File '$FILE_PB':
Name       Regions  Miss  Cover    Lines  Miss  Cover    Branches  Miss  Cover
helper         4     4    0.00%      3     3    0.00%        2     2    0.00%
TOTAL          4     4    0.00%      3     3    0.00%        2     2    0.00%
EOF
annotate_reachability "$TMP/perfcollide_coverage.json" "$TMP/perfcollide_reach.json" \
  "$TMP/perfcollide_html" "$TMP/perfcollide_text" "$TMP/perfcollide_summary.txt" "$TMP/perfcollide_perfunc.txt" >/dev/null \
  || die "F3: annotate_reachability returned non-zero"
# banner classification (funcs/reach_state) — correct before and after the fix.
grep -Eq 'reachable functions +: 1' "$TMP/perfcollide_summary.txt" \
  || die "F3: banner should count exactly 1 reachable function"
grep -Eq 'unreachable functions +: 1' "$TMP/perfcollide_summary.txt" \
  || die "F3: banner should count exactly 1 unreachable function"
# recompute must AGREE with the banner: the live+covered a.c:helper is COUNTED,
# the dead b.c:helper is excluded (handled safely). Pre-fix this DROPS a.c:helper.
grep -q '(1/1)' "$TMP/perfcollide_summary.txt" \
  || die "F3: reachable-only Functions should be 1/1 (live a.c:helper counted, not dropped)"
grep -q '(3/3)' "$TMP/perfcollide_summary.txt" \
  || die "F3: reachable-only Lines should be 3/3 (a.c:helper only)"
grep -q '(3/4)' "$TMP/perfcollide_summary.txt" \
  || die "F3: reachable-only Regions should be 3/4 (a.c:helper only)"
grep -q '(1/2)' "$TMP/perfcollide_summary.txt" \
  || die "F3: reachable-only Branches should be 1/2 (a.c:helper only)"
# the dead b.c:helper must not leak its metrics into the reachable-only denominators.
grep -q '(3/8)' "$TMP/perfcollide_summary.txt" \
  && die "F3: dead b.c:helper leaked into the region denominator (3/8 = both counted)"
echo "[PASS] F3: perfunc recompute disambiguates a static-name collision by (file,symbol), agreeing with the banner"

# ── F4: the explicit JSON "key" field must be read, not just re-derived ──────
# The reachability entry's "mangled" is a v0-mangled symbol on which _reach_key
# is a no-op (its derived key = the full v0 name, which the coverage function's
# legacy-mangled name can never match). Only the EXPLICIT "key" — set to the
# legacy stem the coverage name reduces to under _reach_key — makes the join
# succeed. If `fn.get('key') or _reach_key(name)` ever dropped the explicit
# field, reach_keys would hold the v0 name instead and the function would fall
# through to 'unknown' (line untouched), so this asserts the field is read.
FILE_K="$TMP/keydiverge/lib.rs"
mkdir -p "$TMP/keydiverge"
V0_MANGLED='_RINvCs1a2b3c4d5e6f_3app4workE'
EXPLICIT_KEY='_ZN3app4work'
COV_LEGACY_NAME='_ZN3app4work17h9999999999999999E'
python3 -c "
import re
d = re.compile(r'17h[0-9a-f]{16}E\$')
assert d.sub('', '$V0_MANGLED') == '$V0_MANGLED', 'setup: v0 mangled must be a _reach_key no-op'
assert d.sub('', '$COV_LEGACY_NAME') == '$EXPLICIT_KEY', 'setup: coverage legacy name must reduce to the explicit key'
assert '$V0_MANGLED' != '$EXPLICIT_KEY', 'setup: explicit key must diverge from the derived (v0) key'
" || die "F4 test setup: key divergence preconditions not met"
cat > "$TMP/keydiverge_reach.json" << EOF
{ "reachable": [ { "mangled": "$V0_MANGLED", "key": "$EXPLICIT_KEY", "file": null, "line": null, "indirect_only": false } ],
  "unreachable_defined": [] }
EOF
cat > "$TMP/keydiverge_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "$COV_LEGACY_NAME", "count": 0, "filenames": ["$FILE_K"], "regions": [[3,1,5,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/keydiverge_html/coverage" "$TMP/keydiverge_text/coverage"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$FILE_K</pre></div>"
  for ln in $(seq 1 5); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/keydiverge_html/coverage/lib.rs.html"
{
  printf "Coverage Report\n%s:\n" "$FILE_K"
  for ln in $(seq 1 5); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
} > "$TMP/keydiverge_text/coverage/lib.rs.txt"
: > "$TMP/keydiverge_summary.txt"
annotate_reachability "$TMP/keydiverge_coverage.json" "$TMP/keydiverge_reach.json" \
  "$TMP/keydiverge_html" "$TMP/keydiverge_text" "$TMP/keydiverge_summary.txt" >/dev/null \
  || die "F4: annotate_reachability returned non-zero"
grep -q "reach-amber'><td class='line-number'><a name='L3'" "$TMP/keydiverge_html/coverage/lib.rs.html" \
  || die "F4: coverage function must classify reachable-unreached (reach-amber) via the EXPLICIT key, which diverges from _reach_key(mangled)"
grep -Eq 'reachable functions +: 1' "$TMP/keydiverge_summary.txt" \
  || die "F4: summary should count exactly 1 reachable function (only if the explicit key was read)"
echo "[PASS] F4: explicit JSON \"key\" is read even when it diverges from _reach_key(mangled)"

FILE_L="$TMP/v0exact/lib.rs"
mkdir -p "$TMP/v0exact"
V0_EXACT_NAME='_RINvCs7f8e9d0c1b2a_3app10sync_stateE'
cat > "$TMP/v0exact_reach.json" << EOF
{ "reachable": [ { "mangled": "$V0_EXACT_NAME", "file": null, "line": null, "indirect_only": false } ],
  "unreachable_defined": [] }
EOF
cat > "$TMP/v0exact_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "$V0_EXACT_NAME", "count": 0, "filenames": ["$FILE_L"], "regions": [[3,1,5,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/v0exact_html/coverage" "$TMP/v0exact_text/coverage"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$FILE_L</pre></div>"
  for ln in $(seq 1 5); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/v0exact_html/coverage/lib.rs.html"
{
  printf "Coverage Report\n%s:\n" "$FILE_L"
  for ln in $(seq 1 5); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
} > "$TMP/v0exact_text/coverage/lib.rs.txt"
: > "$TMP/v0exact_summary.txt"
annotate_reachability "$TMP/v0exact_coverage.json" "$TMP/v0exact_reach.json" \
  "$TMP/v0exact_html" "$TMP/v0exact_text" "$TMP/v0exact_summary.txt" >/dev/null \
  || die "v0exact: annotate_reachability returned non-zero"
grep -q "reach-amber'><td class='line-number'><a name='L3'" "$TMP/v0exact_html/coverage/lib.rs.html" \
  || die "v0exact: identical v0-mangled names on both sides must classify reachable-unreached via the exact name join, with no file/line to fall back on"
grep -Eq 'reachable functions +: 1' "$TMP/v0exact_summary.txt" \
  || die "v0exact: summary should count exactly 1 reachable function (only possible via the name join, since the reachability entry carries no file/line)"
echo "[PASS] v0exact: identical v0-mangled reachability/coverage names join by exact NAME, not the (file,line) fallback"

FILE_M="$TMP/v0fallback/lib.rs"
mkdir -p "$TMP/v0fallback"
V0_MISMATCH_NAME='_RINvCs2b3c4d5e6f7a_3app8finalizeE'
LEGACY_MISMATCH_NAME='_ZN3app8finalize17h5555555555555555E'
python3 -c "
import re
d = re.compile(r'17h[0-9a-f]{16}E\$')
assert d.sub('', '$V0_MISMATCH_NAME') == '$V0_MISMATCH_NAME'
assert '$V0_MISMATCH_NAME' != '$LEGACY_MISMATCH_NAME'
assert d.sub('', '$LEGACY_MISMATCH_NAME') != '$V0_MISMATCH_NAME'
" || die "v0fallback test setup: legacy and v0 names must be genuinely non-matching by name or _reach_key"
cat > "$TMP/v0fallback_reach.json" << EOF
{ "reachable": [ { "mangled": "$LEGACY_MISMATCH_NAME", "file": "$FILE_M", "line": 7 } ],
  "unreachable_defined": [] }
EOF
cat > "$TMP/v0fallback_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "$V0_MISMATCH_NAME", "count": 0, "filenames": ["$FILE_M"], "regions": [[7,1,9,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/v0fallback_html/coverage" "$TMP/v0fallback_text/coverage"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$FILE_M</pre></div>"
  for ln in $(seq 1 9); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/v0fallback_html/coverage/lib.rs.html"
{
  printf "Coverage Report\n%s:\n" "$FILE_M"
  for ln in $(seq 1 9); do printf "%5d|%7d|line %d\n" "$ln" 0 "$ln"; done
} > "$TMP/v0fallback_text/coverage/lib.rs.txt"
: > "$TMP/v0fallback_summary.txt"
annotate_reachability "$TMP/v0fallback_coverage.json" "$TMP/v0fallback_reach.json" \
  "$TMP/v0fallback_html" "$TMP/v0fallback_text" "$TMP/v0fallback_summary.txt" >/dev/null \
  || die "v0fallback: annotate_reachability returned non-zero"
grep -q "reach-amber'><td class='line-number'><a name='L7'" "$TMP/v0fallback_html/coverage/lib.rs.html" \
  || die "v0fallback: legacy-mangled reachability entry vs v0-mangled coverage name (same file/line) must still classify reachable-unreached via the (file,line) fallback"
grep -Eq 'reachable functions +: 1' "$TMP/v0fallback_summary.txt" \
  || die "v0fallback: summary should count exactly 1 reachable function via the fallback"
echo "[PASS] v0fallback: legacy-vs-v0 name mismatch with matching (file,line) still classifies via the fallback"

# ── F5: ANSI-colored text output (llvm-cov emits ANSI escapes under a TTY,
# even into -output-dir files) must still be annotated with correct U/R
# markers once the annotator strips them ─────────────────────────────────────
FILE_ANSI="$TMP/ansi/lib.c"
mkdir -p "$TMP/ansi"
cat > "$TMP/ansi_reach.json" << EOF
{ "reachable": [ { "mangled": "work_fn", "file": "$FILE_ANSI", "line": 1 } ],
  "unreachable_defined": [ { "mangled": "dead_fn", "file": "$FILE_ANSI", "line": 5 } ] }
EOF
cat > "$TMP/ansi_coverage.json" << EOF
{ "data": [ { "files": [], "functions": [
    { "name": "work_fn", "count": 0, "filenames": ["$FILE_ANSI"], "regions": [[1,1,3,2,0,0,0,0]] },
    { "name": "dead_fn", "count": 0, "filenames": ["$FILE_ANSI"], "regions": [[5,1,7,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
mkdir -p "$TMP/ansi_html/coverage" "$TMP/ansi_text/coverage"
{
  printf "%s" "<!doctype html><html><head></head><body><div class='centered'><table><div class='source-name-title'><pre>$FILE_ANSI</pre></div>"
  for ln in $(seq 1 7); do
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>line %d</pre></td></tr>" "$ln" "$ln" "$ln" "$ln"
  done
  printf "\n</table></div></body></html>\n"
} > "$TMP/ansi_html/coverage/lib.c.html"
ESC=$'\033'
{
  printf "%sCoverage Report%s\n" "${ESC}[0;36m" "${ESC}[0m"
  printf "%s%s%s:\n" "${ESC}[0m" "${ESC}[0;36m" "$FILE_ANSI"
  printf "%s%5d|%7d|line 1\n" "${ESC}[0m" 1 0
  printf "%5d|%7d|line 2\n" 2 0
  printf "%5d|%7d|line 3\n" 3 0
  printf "%5d|%7d|line 4\n" 4 0
  printf "%5d|%7d|%sline 5%s\n" 5 0 "${ESC}[0;41m" "${ESC}[0m"
  printf "%5d|%7d|line 6\n" 6 0
  printf "%5d|%7d|line 7\n" 7 0
} > "$TMP/ansi_text/coverage/lib.c.txt"
: > "$TMP/ansi_summary.txt"
annotate_reachability "$TMP/ansi_coverage.json" "$TMP/ansi_reach.json" \
  "$TMP/ansi_html" "$TMP/ansi_text" "$TMP/ansi_summary.txt" >/dev/null \
  || die "ansi: annotate_reachability returned non-zero"
grep -Eq '^ *1\|[^|]*\|R ' "$TMP/ansi_text/coverage/lib.c.txt" \
  || die "ansi: reachable work_fn line 1 should be marked R despite ANSI-colored text (header prefixed with escapes)"
grep -Eq '^ *5\|[^|]*\|U ' "$TMP/ansi_text/coverage/lib.c.txt" \
  || die "ansi: unreachable dead_fn line 5 should be marked U despite ANSI-colored text"
grep -q "$ESC" "$TMP/ansi_text/coverage/lib.c.txt" \
  && die "ansi: annotated text output should have the ANSI escapes stripped"
grep -q "reach-grey'><td class='line-number'><a name='L5'" "$TMP/ansi_html/coverage/lib.c.html" \
  || die "ansi: HTML view (no ANSI) must still tint the unreachable line reach-grey"
echo "[PASS] F5: ANSI-colored llvm-cov text output is stripped and still gets U/R markers"

# ── M1: a bare 20-char legacy disambiguator (no stem) must be left unchanged,
# mirroring the C++ legacyStem size()>20 guard ───────────────────────────────
{ reach_py_lib; cat << 'PYEOF'
assert _reach_key('17h0123456789abcdefE') == '17h0123456789abcdefE'
PYEOF
} | python3 - || die "M1: _reach_key must leave a bare 17h<16hex>E string unchanged"
echo "[PASS] M1: _reach_key guards len(entry)>20 like C++ legacyStem"

# ── clang-gated end-to-end against REAL llvm-cov output ──────────────────────
CLANG="$(detect_clang || true)"
COVTOOL=""
if [ -n "$CLANG" ]; then
  ver="${CLANG#clang}"; ver="${ver#-}"
  for c in "llvm-cov${ver:+-$ver}" llvm-cov; do command -v "$c" >/dev/null 2>&1 && { COVTOOL="$c"; break; }; done
  pd=""
  for p in "llvm-profdata${ver:+-$ver}" llvm-profdata; do command -v "$p" >/dev/null 2>&1 && { pd="$p"; break; }; done
fi
if [ -n "$CLANG" ] && [ -n "$COVTOOL" ] && [ -n "${pd:-}" ]; then
  E="$TMP/e2e"; mkdir -p "$E"
  cat > "$E/p.c" << 'EOF'
#include <stdio.h>
int covered_fn(int x) { return x + 1; }
int reachable_unreached(int x) { return x - 1; }
int dead_fn(int x) { return x * 2; }
int main(int argc, char **argv) { printf("%d\n", covered_fn(argc)); return 0; }
EOF
  "$CLANG" -O0 -g -fprofile-instr-generate -fcoverage-mapping -o "$E/p" "$E/p.c"
  LLVM_PROFILE_FILE="$E/p.profraw" "$E/p" >/dev/null
  "$pd" merge -sparse "$E/p.profraw" -o "$E/p.profdata"
  "$COVTOOL" show "$E/p" -instr-profile="$E/p.profdata" -show-line-counts-or-regions \
    -format=html -output-dir="$E/html" 2>/dev/null
  "$COVTOOL" show "$E/p" -instr-profile="$E/p.profdata" -show-line-counts-or-regions \
    -format=text -output-dir="$E/text" 2>/dev/null
  "$COVTOOL" export "$E/p" -instr-profile="$E/p.profdata" --format=text > "$E/coverage.json"
  "$COVTOOL" report "$E/p" -instr-profile="$E/p.profdata" > "$E/summary.txt"
  "$COVTOOL" report "$E/p" -instr-profile="$E/p.profdata" -show-functions "$E/p.c" > "$E/perfunc.txt" 2>/dev/null
  cat > "$E/reach.json" << EOF
{ "reachable": [ { "mangled": "covered_fn", "file": "p.c", "line": 2 },
                 { "mangled": "reachable_unreached", "file": "p.c", "line": 3 } ],
  "unreachable_defined": [ { "mangled": "dead_fn", "file": "p.c", "line": 4 } ] }
EOF
  annotate_reachability "$E/coverage.json" "$E/reach.json" "$E/html" "$E/text" "$E/summary.txt" "$E/perfunc.txt" >/dev/null \
    || die "e2e: annotate_reachability returned non-zero on real llvm-cov output"
  realhtml="$(find "$E/html/coverage" -name 'p.c.html')"
  realtext="$(find "$E/text/coverage" -name 'p.c.txt')"
  grep -q 'reach-grey' "$realhtml"  || die "e2e: real HTML should contain a reach-grey row for dead_fn"
  grep -q 'reach-amber' "$realhtml" || die "e2e: real HTML should contain a reach-amber row"
  grep -Eq '\|U ' "$realtext"       || die "e2e: real text should contain a U marker for dead_fn"
  grep -Eq '\|R ' "$realtext"       || die "e2e: real text should contain an R marker"
  grep -q 'Reachable but NOT reached' "$E/summary.txt" || die "e2e: summary.txt should gain the block"
  # reachable-only recompute: dead_fn excluded → functions 2/3 (covered_fn+main of 3 kept).
  grep -qi 'Reachable-only coverage' "$E/summary.txt" || die "e2e: summary.txt should carry reachable-only table"
  grep -q '(2/3)' "$E/html/index.html" || die "e2e: index.html function coverage should drop to (2/3)"
  echo "[PASS] end-to-end against real llvm-cov"
else
  echo "[SKIP] clang/llvm-cov not available — skipping real-llvm-cov e2e"
fi

echo "[PASS] test_reachability"
