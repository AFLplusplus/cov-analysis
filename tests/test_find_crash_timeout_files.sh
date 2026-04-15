#!/bin/bash
# Verify find_crash_timeout_files emits the right set per layout.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./afl-cov

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)

# AFL single: 1 crash + 1 timeout = 2
AFL_DIR="$TMP/afl-single"; mkfixture_afl_single "$AFL_DIR"
FUZZER_LAYOUT="afl"
find_crash_timeout_files | assert_count 2 "afl-single crash+timeout"

# AFL parallel: 1 crash (main) + 1 timeout (secondary1) = 2
AFL_DIR="$TMP/afl-parallel"; mkfixture_afl_parallel "$AFL_DIR"
FUZZER_LAYOUT="afl"
find_crash_timeout_files | assert_count 2 "afl-parallel crash+timeout"

# libFuzzer flat: 5 artifacts (crash/leak/oom/timeout/slow-unit)
AFL_DIR="$TMP/libfuzzer"; mkfixture_libfuzzer "$AFL_DIR"
FUZZER_LAYOUT="flat"
find_crash_timeout_files | assert_count 5 "libfuzzer artifacts"

# honggfuzz flat: 2 SIG*.fuzz crash files
AFL_DIR="$TMP/honggfuzz"; mkfixture_honggfuzz "$AFL_DIR"
FUZZER_LAYOUT="flat"
find_crash_timeout_files | assert_count 2 "honggfuzz crashes"

echo "[PASS] find_crash_timeout_files"
