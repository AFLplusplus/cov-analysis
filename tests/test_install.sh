#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
make install DESTDIR="$TMP/root" PREFIX=/usr >/dev/null || die "make install failed for a new DESTDIR"
test -x "$TMP/root/usr/bin/cov-analysis" || die "installed executable missing"

echo "[PASS] test_install"
