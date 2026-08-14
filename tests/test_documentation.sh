#!/usr/bin/env bash
# Consistency test: every option a command accepts must appear in its --help
# output AND in README.md.
#
# The field report started with a documented workflow the tool did not
# implement. The reverse — a feature nobody can find — is the same failure, so
# the parser, the help text and the README are checked against each other.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

README="README.md"
test -s "$README" || die "README.md is missing"

# Long options the argument parser of a command accepts.
parser_options() {
  local fn="$1"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
    inside && /^}/ { inside = 0 }
    inside {
      line = $0
      while (match(line, /--[a-z][a-z0-9-]+\)/)) {
        opt = substr(line, RSTART, RLENGTH - 1)
        print opt
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' cov-analysis | sort -u
}

check_command() {
  local cmd="$1" fn="$2" help opt missing_help="" missing_readme=""
  help="$(bash ./cov-analysis "$cmd" --help 2>&1)"
  while read -r opt; do
    test -n "$opt" || continue
    case "$opt" in
      --help) continue ;;
    esac
    printf '%s\n' "$help" | grep -q -- "$opt" \
      || missing_help="$missing_help $opt"
    grep -q -- "$opt" "$README" \
      || missing_readme="$missing_readme $opt"
  done < <(parser_options "$fn")
  test -z "$missing_help" \
    || die "cov-analysis $cmd accepts undocumented options (not in --help):$missing_help"
  test -z "$missing_readme" \
    || die "cov-analysis $cmd options missing from README.md:$missing_readme"
  echo "[PASS] $cmd options are documented in --help and README.md"
}

check_command report cmd_report
check_command stability cmd_stability
check_command search cmd_search
check_command diff cmd_diff

# Report artifacts the tool publishes must be described in the README.
for artifact in summary.txt gaps.txt coverage.json coverage.profdata \
                attribution.txt; do
  grep -q "$artifact" "$README" \
    || die "published artifact $artifact is not described in README.md"
done
echo "[PASS] published report artifacts are described"

# Every subcommand the dispatcher accepts must have a help block and a README
# section, so no workflow is reachable but undocumented.
for cmd in report build driver diff stability search; do
  bash ./cov-analysis "$cmd" --help >/dev/null 2>&1 \
    || die "cov-analysis $cmd has no --help"
  grep -q "cov-analysis $cmd" "$README" \
    || die "cov-analysis $cmd is not documented in README.md"
done
echo "[PASS] every subcommand is documented"

echo "[PASS] test_documentation"
