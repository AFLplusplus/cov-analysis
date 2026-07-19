#!/usr/bin/env bash
# Behavior test: `cov-analysis diff` with no arguments and no default reports in
# the current directory prints help (exit 0) instead of erroring. When a default
# report IS present, the original "report does not exist" error is preserved.
# Pure CLI behavior — no toolchain required.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
COV="$(pwd)/cov-analysis"

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)
cd "$TMP"

# ── no args, no default reports: must print help and exit 0 ──────────────────
out=$(bash "$COV" diff 2>&1); rc=$?
assert_eq "$rc" "0" "diff: no args + no default reports must exit 0 (help, not error)"
printf '%s\n' "$out" | grep -q 'Usage: cov-analysis diff' \
  || die "diff: expected help output for bare 'diff' in an empty dir; got:
$out"
if printf '%s\n' "$out" | grep -qi 'does not exist'; then
  die "diff: must not print a 'does not exist' error for bare 'diff' in an empty dir"
fi
echo "[PASS] diff no-args in empty dir prints help"

# ── no args, but a default report present: keep the original error ───────────
printf '{}' > "$TMP/coverage.json"
out=$(bash "$COV" diff 2>&1); rc=$?
assert_eq "$rc" "1" "diff: no args but coverage.json present keeps the missing-old-report error"
printf '%s\n' "$out" | grep -qi 'does not exist' \
  || die "diff: expected the missing-report error when a default report exists; got:
$out"
echo "[PASS] diff no-args with one report still errors (not help)"

echo "[PASS] test_diff_no_args"
