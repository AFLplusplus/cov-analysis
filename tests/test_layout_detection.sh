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

AFL_DIR="$TMP/libafl"
mkfixture_libafl "$AFL_DIR"
out=$(detect_fuzzer_layout)
assert_eq "$out" "libafl" "libafl corpus+crashes"

AFL_DIR="$TMP/libafl-queue"
mkfixture_libafl_queue "$AFL_DIR"
out=$(detect_fuzzer_layout)
assert_eq "$out" "libafl" "libafl queue+solutions"

AFL_DIR="$TMP/libafl-crashes"
mkdir -p "$AFL_DIR/crashes"
: > "$AFL_DIR/crashes/c0ffee1234567890"
out=$(detect_fuzzer_layout)
assert_eq "$out" "libafl" "libafl crashes only"

AFL_DIR="$TMP/afl-crashes"
mkdir -p "$AFL_DIR/crashes"
: > "$AFL_DIR/crashes/id:000000,sig:11,src:000"
out=$(detect_fuzzer_layout)
assert_eq "$out" "afl" "afl crashes only"

AFL_DIR="$TMP/libfuzzer-artifacts"
mkfixture_libfuzzer "$AFL_DIR"
mkdir -p "$AFL_DIR/crashes"
: > "$AFL_DIR/crashes/crash-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
out=$(detect_fuzzer_layout)
assert_eq "$out" "flat" "libfuzzer corpus with an artifact subdirectory"

AFL_DIR="$TMP/libafl-corpus-only"
mkdir -p "$AFL_DIR/corpus"
: > "$AFL_DIR/corpus/3f2a9c1d7e8b4a60"
: > "$AFL_DIR/.lafl_lock"
out=$(detect_fuzzer_layout)
assert_eq "$out" "libafl" "libafl corpus with nothing beside it"

AFL_DIR="$TMP/flat-with-corpus-subdir"
mkfixture_libfuzzer "$AFL_DIR"
mkdir -p "$AFL_DIR/corpus"
: > "$AFL_DIR/corpus/seed1"
out=$(detect_fuzzer_layout)
assert_eq "$out" "flat" "flat corpus that holds a corpus/ subdirectory"

AFL_DIR="$TMP/libafl-with-stats"
mkfixture_libafl "$AFL_DIR"
: > "$AFL_DIR/fuzzer_stats.toml"
out=$(detect_fuzzer_layout)
assert_eq "$out" "libafl" "libafl corpus+crashes beside a stats file"

AFL_DIR="$TMP/hidden-only"
mkdir -p "$AFL_DIR"
: > "$AFL_DIR/.metadata"
out=$(detect_fuzzer_layout)
assert_eq "$out" "empty" "hidden files only"

# Empty directory
AFL_DIR="$TMP/empty"
mkdir -p "$AFL_DIR"
out=$(detect_fuzzer_layout)
assert_eq "$out" "empty" "empty-dir"

echo "[PASS] detect_fuzzer_layout"
