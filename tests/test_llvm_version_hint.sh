#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\necho "clang version 22.1.0"\n' > "$BIN/upstream"
printf '#!/bin/sh\necho "Apple clang version 15.0.0"\n' > "$BIN/apple-clang"
printf '#!/bin/sh\necho "Apple clang version 99.0.0"\n' > "$BIN/clang-15"
for name in llvm-cov llvm-cov-15 llvm-cov-22; do
  printf '#!/bin/sh\nexit 0\n' > "$BIN/$name"
done
chmod +x "$BIN"/*
PATH="$BIN:/usr/bin:/bin"

assert_eq "$(CC=upstream llvm_version_hint)" "22" "upstream Clang major"
assert_eq "$(CC=upstream find_tool llvm-cov)" "llvm-cov-22" "upstream versioned tool"
assert_eq "$(CC=apple-clang llvm_version_hint)" "" "Apple Clang has no inferred major"
assert_eq "$(CC=apple-clang find_tool llvm-cov)" "llvm-cov" "Apple Clang falls back to bare tool"
assert_eq "$(CC=clang-15 llvm_version_hint)" "15" "explicit suffix remains authoritative"
assert_eq "$(CC=clang-15 find_tool llvm-cov)" "llvm-cov-15" "explicit suffix selects versioned tool"

echo "[PASS] test_llvm_version_hint"
