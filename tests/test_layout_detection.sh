#!/usr/bin/env bash
# Verify detect_fuzzer_layout() correctly classifies each supported layout.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)

# AFL++ single-instance
AFL_DIR="$TMP/afl-single"
mkfixture_afl_single "$AFL_DIR"
out=$(detect_fuzzer_layout)
assert_eq "$out" "afl" "afl-single"

# AFL++ parallel (sync_dir)
AFL_DIR="$TMP/afl-parallel"
mkfixture_afl_parallel "$AFL_DIR"
out=$(detect_fuzzer_layout)
assert_eq "$out" "afl" "afl-parallel"

# libFuzzer flat corpus
AFL_DIR="$TMP/libfuzzer"
mkfixture_libfuzzer "$AFL_DIR"
out=$(detect_fuzzer_layout)
assert_eq "$out" "flat" "libfuzzer-flat"

# honggfuzz flat workspace
AFL_DIR="$TMP/honggfuzz"
mkfixture_honggfuzz "$AFL_DIR"
out=$(detect_fuzzer_layout)
assert_eq "$out" "flat" "honggfuzz-flat"

# Empty directory
AFL_DIR="$TMP/empty"
mkdir -p "$AFL_DIR"
out=$(detect_fuzzer_layout)
assert_eq "$out" "empty" "empty-dir"

echo "[PASS] detect_fuzzer_layout"
