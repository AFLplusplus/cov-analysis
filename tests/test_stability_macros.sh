#!/usr/bin/env bash
# Regression test: a macro DEFINITION line must not be reported as an unstable
# location.
#
# llvm-cov attributes every macro expansion to the line of the #define, so a
# macro used from many varying call sites shows up as one "unstable" line in a
# header — a non-location the user cannot act on (the field report names
# SSH_LOG at priv.h:283 and SAFE_FREE at priv.h:375).
#
# The stub llvm-cov below reports priv.h:283 as varying and marks it, in the
# JSON export, as the target of several expansions.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/corpus"
printf x > "$TMP/corpus/seed"

cat > "$TMP/target" <<'EOF'
#!/bin/bash
p="${LLVM_PROFILE_FILE//%p/$$}"
mkdir -p "$(dirname "$p")"
printf profile > "$p"
EOF
cat > "$BIN/llvm-profdata" <<'EOF'
#!/bin/bash
out=""
while test $# -gt 0; do
  if test "$1" = -o; then out="$2"; shift 2; else shift; fi
done
printf merged > "$out"
EOF
cat > "$BIN/llvm-cov" <<'EOF'
#!/bin/bash
test "$1" = export || exit 0
shift
fmt=""; profile=""
for arg in "$@"; do
  case "$arg" in
    --format=*) fmt="${arg#*=}" ;;
    -instr-profile=*) profile="${arg#*=}" ;;
  esac
done
if test "$fmt" = lcov; then
  # src/session.c:12 genuinely varies; priv.h:283 is a macro definition whose
  # count is the sum over all expansion sites, so it varies too.
  case "$profile" in
    *merged_run_2.profdata)
      printf 'SF:/src/session.c\nDA:12,3\nDA:20,4\nend_of_record\n'
      printf 'SF:/src/priv.h\nDA:283,9\nend_of_record\n'
      ;;
    *)
      printf 'SF:/src/session.c\nDA:12,5\nDA:20,4\nend_of_record\n'
      printf 'SF:/src/priv.h\nDA:283,14\nend_of_record\n'
      ;;
  esac
  exit 0
fi
# Shape mirrors real llvm-cov output: filenames[] is indexed by file id,
# source_region[6] is the expanded file id, and the macro body shows up as the
# target regions carrying that same file id.
cat <<'JSON'
{"data":[{"files":[
  {"filename":"/src/session.c","expansions":[
    {"filenames":["/src/session.c","/src/priv.h"],
     "source_region":[12,3,12,40,5,0,1,1],
     "target_regions":[[12,3,12,40,5,0,1,1],[283,20,283,60,5,1,0,0],
                       [283,40,283,55,5,1,0,0]]},
    {"filenames":["/src/session.c","/src/priv.h"],
     "source_region":[20,3,20,40,4,0,1,1],
     "target_regions":[[20,3,20,40,4,0,1,1],[283,20,283,60,4,1,0,0]]}]},
  {"filename":"/src/priv.h","expansions":[]}],
 "functions":[]}]}
JSON
EOF
chmod +x "$TMP/target" "$BIN/llvm-profdata" "$BIN/llvm-cov"
export CC=/bin/true

out=$(PATH="$BIN:/usr/bin:/bin" bash ./cov-analysis stability -d "$TMP/corpus" \
  -e "$TMP/target @@" -n 3 2>&1) || die "stability failed: $out"

# The real location stays in the actionable list ...
printf '%s\n' "$out" | grep -q '/src/session.c:12' \
  || die "the genuinely unstable line is missing: $out"

# ... and the macro definition is called out as one, not left as a bare location.
printf '%s\n' "$out" | grep -qi 'macro definition' \
  || die "the macro definition line was not identified as one: $out"
printf '%s\n' "$out" | grep -q '/src/priv.h:283' \
  || die "the macro definition line was dropped entirely: $out"
printf '%s\n' "$out" | grep -q '2 expansion site' \
  || die "the number of expansion sites was not reported: $out"

macro_at=$(printf '%s\n' "$out" | grep -n 'Macro definitions' | head -1 | cut -d: -f1)
priv_at=$(printf '%s\n' "$out" | grep -n '/src/priv.h:283' | head -1 | cut -d: -f1)
sess_at=$(printf '%s\n' "$out" | grep -n '/src/session.c:12' | head -1 | cut -d: -f1)
test -n "$macro_at" || die "no macro block header: $out"
test "$priv_at" -gt "$macro_at" || die "priv.h:283 is not under the macro block: $out"
test "$sess_at" -lt "$macro_at" || die "session.c:12 must stay in the main list: $out"
echo "[PASS] macro definition lines are separated from real locations"

# ── --exclude-regex drops files from the analysis entirely ───────────────────
out=$(PATH="$BIN:/usr/bin:/bin" bash ./cov-analysis stability -d "$TMP/corpus" \
  -e "$TMP/target @@" -n 3 --exclude-regex '\.h$' 2>&1) || die "stability failed: $out"
printf '%s\n' "$out" | grep -q '/src/priv.h' \
  && die "--exclude-regex did not drop the header: $out"
printf '%s\n' "$out" | grep -q '/src/session.c:12' \
  || die "--exclude-regex dropped more than the header: $out"
echo "[PASS] --exclude-regex removes matching files"

# ── ... and composes with the inclusive -s filter ────────────────────────────
out=$(PATH="$BIN:/usr/bin:/bin" bash ./cov-analysis stability -d "$TMP/corpus" \
  -e "$TMP/target @@" -n 3 -s /src/ --exclude-regex 'session' 2>&1) \
  || die "stability failed: $out"
printf '%s\n' "$out" | grep -q '/src/session.c' \
  && die "--exclude-regex must apply on top of -s: $out"
printf '%s\n' "$out" | grep -q '/src/priv.h:283' \
  || die "-s /src/ should have kept priv.h: $out"
echo "[PASS] --exclude-regex composes with -s"

echo "[PASS] test_stability_macros"
