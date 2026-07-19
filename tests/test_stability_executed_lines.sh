#!/usr/bin/env bash
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
  if test "$1" = "-o"; then out="$2"; shift 2; else shift; fi
done
printf merged > "$out"
EOF
cat > "$BIN/llvm-cov" <<'EOF'
#!/bin/bash
case "$1" in
  export)
    profile=""
    for arg in "$@"; do case "$arg" in -instr-profile=*) profile="${arg#*=}";; esac; done
    case "$profile" in
      *merged_run_2.profdata)
        printf 'SF:/src/stability.c\nDA:1,7\nDA:2,0\nDA:3,0\nend_of_record\n'
        ;;
      *)
        printf 'SF:/src/stability.c\nDA:1,7\nDA:2,0\nDA:3,1\nend_of_record\n'
        ;;
    esac
    ;;
esac
EOF
chmod +x "$TMP/target" "$BIN/llvm-profdata" "$BIN/llvm-cov"
export CC=/bin/true

out=$(PATH="$BIN:/usr/bin:/bin" bash ./cov-analysis stability -d "$TMP/corpus" \
  -e "$TMP/target @@" -n 3 2>&1) || die "stability command failed: $out"
printf '%s\n' "$out" | grep -q '50.0% (1/2 executed lines stable)' \
  || die "stability denominator/counts are wrong: $out"
printf '%s\n' "$out" | grep -q '/src/stability.c:3' \
  || die "zero-to-positive line was not classified unstable: $out"
if printf '%s\n' "$out" | grep -q '/src/stability.c:2'; then
  die "permanently uncovered line entered the stability denominator"
fi

cat > "$BIN/llvm-cov" <<'EOF'
#!/bin/bash
if test "$1" = export; then
  printf 'SF:/src/stability.c\nDA:1,0\nDA:2,0\nend_of_record\n'
fi
EOF
chmod +x "$BIN/llvm-cov"
out=$(PATH="$BIN:/usr/bin:/bin" bash ./cov-analysis stability -d "$TMP/corpus" \
  -e "$TMP/target @@" -n 2 2>&1) || die "all-zero stability command failed: $out"
printf '%s\n' "$out" | grep -q 'Stability   : n/a (0/0 executed lines stable)' \
  || die "all-zero stability result should be n/a: $out"

echo "[PASS] test_stability_executed_lines"
