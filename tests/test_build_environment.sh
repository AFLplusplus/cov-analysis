#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
for name in clang clang++ clang-19 clang++-19 custom-wrapper custom-cxx; do
  printf '#!/bin/sh\nexit 0\n' > "$BIN/$name"
  chmod +x "$BIN/$name"
done
P="$BIN:/usr/bin:/bin"
PROBE='printf "%s\n%s\n%s\n%s\n%s\n%s\n" "$CC" "$CXX" "$CFLAGS" "$CXXFLAGS" "$CPPFLAGS" "$LDFLAGS"'

out=$(env -u CC -u CXX PATH="$P" bash ./cov-analysis build bash -c "$PROBE" 2>/dev/null) || die "auto compiler detection failed"
assert_eq "$(printf '%s\n' "$out" | sed -n '1p')" "clang" "auto CC"
assert_eq "$(printf '%s\n' "$out" | sed -n '2p')" "clang++" "auto CXX"

out=$(env -u CXX PATH="$P" CC=clang bash ./cov-analysis build bash -c "$PROBE" 2>/dev/null) || die "CC-only compiler derivation failed"
assert_eq "$(printf '%s\n' "$out" | sed -n '2p')" "clang++" "CC-only derives CXX"

out=$(env -u CC PATH="$P" CXX=clang++ bash ./cov-analysis build bash -c "$PROBE" 2>/dev/null) || die "CXX-only compiler derivation failed"
assert_eq "$(printf '%s\n' "$out" | sed -n '1p')" "clang" "CXX-only derives CC"

out=$(env -u CC PATH="$P" CXX=clang++-19 bash ./cov-analysis build bash -c "$PROBE" 2>/dev/null) || die "versioned CXX-only compiler derivation failed"
assert_eq "$(printf '%s\n' "$out" | sed -n '1p')" "clang-19" "versioned CXX-only derives CC"

out=$(env -u CC PATH="$P" CXX="$BIN/clang++-19" bash ./cov-analysis build bash -c "$PROBE" 2>/dev/null) || die "absolute CXX-only compiler derivation failed"
assert_eq "$(printf '%s\n' "$out" | sed -n '1p')" "$BIN/clang-19" "absolute CXX-only derives CC"

out=$(env -u CXX PATH="$P" CC=clang-19 bash ./cov-analysis build bash -c "$PROBE" 2>/dev/null) || die "versioned compiler derivation failed"
assert_eq "$(printf '%s\n' "$out" | sed -n '2p')" "clang++-19" "versioned CXX"

out=$(env -u CXX PATH="$P" CC="$BIN/clang-19" bash ./cov-analysis build bash -c "$PROBE" 2>/dev/null) || die "absolute compiler derivation failed"
assert_eq "$(printf '%s\n' "$out" | sed -n '2p')" "$BIN/clang++-19" "absolute CXX"

if env -u CXX PATH="$P" CC="$BIN/custom-wrapper" bash ./cov-analysis build true >"$TMP/wrapper.out" 2>"$TMP/wrapper.err"; then
  die "custom CC without CXX should fail"
fi
grep -q 'Set both CC and CXX' "$TMP/wrapper.err" || die "custom wrapper failure is not actionable"

out=$(env PATH="$P" CC="$BIN/custom-wrapper" CXX="$BIN/custom-cxx" \
  CFLAGS='-O2 -I caller/include' CXXFLAGS='-O3 -stdlib=libc++' \
  CPPFLAGS='-DCALLER_MACRO=1' LDFLAGS='-Wl,--as-needed -Lcaller/lib' \
  bash ./cov-analysis build bash -c "$PROBE" 2>/dev/null) || die "flag preservation probe failed"
cflags=$(printf '%s\n' "$out" | sed -n '3p')
cxxflags=$(printf '%s\n' "$out" | sed -n '4p')
cppflags=$(printf '%s\n' "$out" | sed -n '5p')
ldflags=$(printf '%s\n' "$out" | sed -n '6p')
assert_eq "$(printf '%s' "$cflags" | grep -o -- '-O2' | wc -l)" "1" "CFLAGS caller flag count"
assert_eq "$(printf '%s' "$cxxflags" | grep -o -- '-O3' | wc -l)" "1" "CXXFLAGS caller flag count"
assert_eq "$(printf '%s' "$cppflags" | grep -o -- '-DCALLER_MACRO=1' | wc -l)" "1" "CPPFLAGS caller flag count"
assert_eq "$(printf '%s' "$ldflags" | grep -o -- '-Wl,--as-needed' | wc -l)" "1" "LDFLAGS caller flag count"
case "$cflags $cxxflags" in *-fprofile-instr-generate*'-fcoverage-mapping'*) ;; *) die "compile coverage flags missing" ;; esac
case "$cppflags" in *-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1*) ;; *) die "coverage preprocessor definition missing" ;; esac
case "$ldflags" in *-fprofile-instr-generate*) ;; *) die "coverage linker flag missing" ;; esac

echo "[PASS] test_build_environment"
