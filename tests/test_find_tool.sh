#!/usr/bin/env bash
# Verify find_tool() selects the LLVM tool matching the chosen clang version.
#
# Regression: with CC=clang-22 selected, find_tool must return llvm-profdata-22
# rather than a mismatched bare llvm-profdata, so profraw from clang-22 merges.
#
# Isolation: we exercise find_tool against a fake tool name ("mytool") and fake
# clang stubs on a prepended PATH, so the result never depends on which real
# LLVM tools happen to be installed on the host.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)
BIN="$TMP/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# stub <name> [body] — create an executable stub in $BIN.
stub() {
  printf '#!/bin/sh\n%s\n' "${2:-:}" > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# ── Case 1: versioned CC selects the matching versioned tool ─────────────────
rm -f "$BIN"/mytool*
stub mytool
stub mytool-22
CC=clang-22 CXX=clang++-22
out=$(find_tool mytool)
assert_eq "$out" "mytool-22" "versioned-CC-prefers-matching-tool"

# ── Case 2: versioned CC, matching tool absent → fall back to bare ───────────
rm -f "$BIN"/mytool*
stub mytool
CC=clang-22 CXX=clang++-22
out=$(find_tool mytool)
assert_eq "$out" "mytool" "versioned-CC-falls-back-to-bare"

# ── Case 3: CC unset → version derived from `clang --version` ────────────────
rm -f "$BIN"/mytool* "$BIN"/clang
stub clang 'echo "clang version 19.1.0"'
stub mytool
stub mytool-19
unset CC CXX
out=$(find_tool mytool)
assert_eq "$out" "mytool-19" "bare-clang-version-prefers-matching-tool"

# ── Case 4: no usable hint → versioned loop covers modern releases (>20) ──────
rm -f "$BIN"/mytool* "$BIN"/clang
stub clang 'echo "not-clang 9.9"'   # no "clang version" line → empty hint
stub mytool-24                      # only a high-versioned tool exists
unset CC CXX
out=$(find_tool mytool)
assert_eq "$out" "mytool-24" "loop-covers-modern-versions"

echo "[PASS] find_tool"
