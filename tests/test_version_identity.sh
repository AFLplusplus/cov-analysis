#!/usr/bin/env bash
# Regression test: -V must identify the copy that is running, not just its
# version string.
#
# Field report: a months-old checkout on a remote host rejected --name and
# printed the same "cov-analysis-1.2-dev" as the current one. The conclusion
# drawn was "this version does not support multiple campaigns" — it was simply
# an old copy, and -V could not tell them apart.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT

out=$(bash "$ROOT/cov-analysis" -V)
assert_eq "$?" "0" "-V must exit 0"

printf '%s\n' "$out" | grep -qE '^cov-analysis-[^ ]+ \(sha256:[0-9a-f]{12}, /.*cov-analysis\)$' \
  || die "-V must print version, a 12-character content hash and the script path: $out"
printf '%s\n' "$out" | grep -qF "$ROOT/cov-analysis" \
  || die "-V must name the copy that ran: $out"
echo "[PASS] -V identifies the running copy"

# Two copies that differ by one byte must be distinguishable.
cp "$ROOT/cov-analysis" "$TMP/a"
cp "$ROOT/cov-analysis" "$TMP/b"
printf '# one byte of difference\n' >> "$TMP/b"
hash_of() { bash "$1" -V | sed 's/.*sha256:\([0-9a-f]*\).*/\1/'; }
version_of() { bash "$1" -V | sed 's/^\(cov-analysis-[^ ]*\).*/\1/'; }
ha=$(hash_of "$TMP/a"); hb=$(hash_of "$TMP/b")
test "$ha" != "$hb" || die "two different copies printed the same hash: $ha"
assert_eq "$(version_of "$TMP/a")" "$(version_of "$TMP/b")" \
  "the version string must not change with the content"
assert_eq "$(hash_of "$TMP/a")" "$(hash_of "$ROOT/cov-analysis")" \
  "an identical copy must print an identical hash"
echo "[PASS] copies that differ print different hashes"

# Every subcommand answers -V the same way.
for sub in report build driver diff stability search; do
  got=$(bash "$ROOT/cov-analysis" "$sub" -V 2>&1)
  assert_eq "$got" "$out" "$sub -V disagrees with the top-level -V"
done
echo "[PASS] every subcommand agrees on -V"

echo "[PASS] test_version_identity"
