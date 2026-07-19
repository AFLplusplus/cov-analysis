#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\nprintf "rustc 1.90.0\\nLLVM version: 21.1.0\\n"\n' > "$BIN/rustc"
for name in clang llvm-cov llvm-profdata; do
  printf '#!/bin/sh\necho "LLVM version 23.0.0"\n' > "$BIN/$name"
  printf '#!/bin/sh\necho "LLVM version 21.1.0"\n' > "$BIN/$name-21"
done
chmod +x "$BIN"/*
PATH="$BIN:/usr/bin:/bin"

toolchain=$(select_rust_llvm_toolchain) || die "matching versioned Rust LLVM set was not selected"
IFS=$'\t' read -r major clang cov prof <<< "$toolchain"
assert_eq "$major" "21" "rustc LLVM major"
assert_eq "$clang" "$BIN/clang-21" "matching clang"
assert_eq "$cov" "$BIN/llvm-cov-21" "matching llvm-cov"
assert_eq "$prof" "$BIN/llvm-profdata-21" "matching llvm-profdata"

for name in clang llvm-cov llvm-profdata; do
  printf '#!/bin/sh\necho "LLVM version 21.1.0"\n' > "$BIN/$name"
done
toolchain=$(select_rust_llvm_toolchain) || die "matching unversioned Rust LLVM set was not selected"
IFS=$'\t' read -r major clang cov prof <<< "$toolchain"
assert_eq "$clang" "$BIN/clang" "matching bare clang preferred"
assert_eq "$cov" "$BIN/llvm-cov" "matching bare llvm-cov preferred"
assert_eq "$prof" "$BIN/llvm-profdata" "matching bare llvm-profdata preferred"

printf '#!/bin/sh\necho "LLVM version 23.0.0"\n' > "$BIN/llvm-profdata"
printf '#!/bin/sh\necho "LLVM version 23.0.0"\n' > "$BIN/llvm-profdata-21"
chmod +x "$BIN/llvm-profdata-21"
if select_rust_llvm_toolchain >/dev/null 2>&1; then
  die "incomplete matching Rust LLVM set should fail"
fi

echo "[PASS] test_rust_llvm_toolchain"
