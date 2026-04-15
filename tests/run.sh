#!/bin/bash
# tests/run.sh — run every tests/test_*.sh, report pass/fail.
set -uo pipefail

cd "$(dirname "$0")/.."

pass=0
fail=0
failed_tests=()

shopt -s nullglob
for t in tests/test_*.sh; do
  echo "─── $t ───"
  if bash "$t"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_tests+=("$t")
  fi
done

echo
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  printf 'Failed: %s\n' "${failed_tests[@]}"
  exit 1
fi
