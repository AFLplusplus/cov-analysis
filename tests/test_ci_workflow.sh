#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."

WF=.github/workflows/ci.yml

[ -f "$WF" ] || { echo "[FAIL] $WF is missing"; exit 1; }
grep -q '^on:' "$WF"              || { echo "[FAIL] $WF has no trigger definition"; exit 1; }
grep -q 'actions/checkout' "$WF"  || { echo "[FAIL] $WF does not check out the repository"; exit 1; }
grep -q 'make test' "$WF"         || { echo "[FAIL] $WF does not run make test"; exit 1; }

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WF" \
    || { echo "[FAIL] $WF is not valid YAML"; exit 1; }
fi

echo "[PASS] ci workflow"
