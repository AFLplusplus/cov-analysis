#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis
set +e

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
CLANG="$(detect_clang || true)"
if test -z "$CLANG"; then
  echo "[SKIP] generated driver test (clang unavailable)"
  exit 0
fi
export CC="$CLANG"
PROFDATA="$(find_tool llvm-profdata || true)"
if test -z "$PROFDATA"; then
  echo "[SKIP] generated driver test (matching llvm-profdata unavailable)"
  exit 0
fi

DRIVER="$TMP/coverage_driver.c"
bash ./cov-analysis driver -o "$DRIVER" >/dev/null
if sed -n '/static void crash_handler/,/^}/p' "$DRIVER" | grep -q 'fprintf'; then
  die "generated crash handler still performs stdio"
fi
if grep -q 'Coverage gathering aborted' "$DRIVER"; then
  die "generated driver still emits crash-handler diagnostics"
fi
cat > "$TMP/harness.c" <<'EOF'
#include <stddef.h>
int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size) {
  if (size > 0 && data[0] == 'X') {
    *(volatile int *)0 = 1;
  }
  return 0;
}
EOF
"$CLANG" -fprofile-instr-generate -fcoverage-mapping "$DRIVER" "$TMP/harness.c" -o "$TMP/cov" \
  || die "generated driver compilation failed"
printf N > "$TMP/normal"
LLVM_PROFILE_FILE="$TMP/normal.profraw" "$TMP/cov" "$TMP/normal" >/dev/null 2>&1 \
  || die "generated driver normal replay failed"
test -s "$TMP/normal.profraw" || die "normal replay did not write a profile"
"$PROFDATA" merge -sparse "$TMP/normal.profraw" -o "$TMP/normal.profdata" \
  || die "normal replay profile is invalid"

printf X > "$TMP/crash"
( LLVM_PROFILE_FILE="$TMP/crash.profraw" "$TMP/cov" "$TMP/crash" >/dev/null 2>&1 ) 2>/dev/null
rc=$?
test "$rc" -ne 0 || die "crashing driver input unexpectedly returned success"
if test -s "$TMP/crash.profraw"; then
  "$PROFDATA" merge -sparse "$TMP/crash.profraw" -o "$TMP/crash.profdata" \
    || die "crash-time profile was written but invalid"
else
  echo "[SKIP] crash-time profile output unavailable on this profiling runtime"
fi

# A harness that chdir()s must not invalidate the relative paths it was handed.
mkdir -p "$TMP/sandbox" "$TMP/rel"
printf a > "$TMP/rel/a"
printf b > "$TMP/rel/b"
: > "$TMP/rel/zerolen"
cat > "$TMP/harness_chdir.c" <<'EOF'
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>
int LLVMFuzzerInitialize(int *argc, char ***argv) {
  const char *s = getenv("SANDBOX");
  (void)argc; (void)argv;
  if (s && chdir(s) != 0) _exit(3);
  return 0;
}
int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size) {
  (void)data;
  return size > 0 ? 0 : 0;
}
EOF
"$CLANG" -fprofile-instr-generate -fcoverage-mapping "$DRIVER" "$TMP/harness_chdir.c" \
  -o "$TMP/cov2" || die "chdir harness compilation failed"

out=$(cd "$TMP/rel" && LLVM_PROFILE_FILE="$TMP/chdir.profraw" SANDBOX="$TMP/sandbox" \
  "$TMP/cov2" a b 2>&1)
rc=$?
assert_eq "$rc" "0" "driver failed on relative paths after the harness chdir()ed: $out"
n=$(printf '%s\n' "$out" | grep -c '^Running: ')
assert_eq "$n" "2" "driver did not process both inputs after the harness chdir()ed: $out"

out=$(LLVM_PROFILE_FILE="$TMP/missing.profraw" "$TMP/cov" "$TMP/does-not-exist" 2>&1)
rc=$?
assert_eq "$rc" "2" "driver must fail when an input cannot be read: $out"
printf '%s\n' "$out" | grep -q 'does-not-exist' \
  || die "driver did not name the unreadable input: $out"

out=$(LLVM_PROFILE_FILE="$TMP/zerolen.profraw" "$TMP/cov" "$TMP/rel/zerolen" 2>&1)
rc=$?
assert_eq "$rc" "0" "an empty input must not fail the driver: $out"
printf '%s\n' "$out" | grep -q 'empty input' \
  || die "driver did not report the empty input: $out"

out=$("$TMP/cov" --printsignature 2>&1)
rc=$?
assert_eq "$rc" "0" "--printsignature must exit 0 so driver detection keeps working: $out"
printf '%s\n' "$out" | grep -q 'SIGNATURE_LLVMFUZZERTESTONEINPUT_COVERAGE' \
  || die "--printsignature no longer prints the detection signature: $out"

"$CLANG" -MJ "$TMP/entry.json" -fprofile-instr-generate -fcoverage-mapping \
  -c "$DRIVER" -o "$TMP/coverage_driver.o" || die "driver compilation-database probe failed"
{
  printf '[\n'
  sed '$s/,$//' "$TMP/entry.json"
  printf ']\n'
} > "$TMP/compile_commands.json"
CLANGD=""
base=$(basename "$CLANG")
case "$base" in clang-*) command -v "clangd-${base#clang-}" >/dev/null 2>&1 && CLANGD="clangd-${base#clang-}";; esac
test -n "$CLANGD" || CLANGD="$(command -v clangd 2>/dev/null || true)"
if test -n "$CLANGD"; then
  "$CLANGD" --check="$DRIVER" --compile-commands-dir="$TMP" >"$TMP/clangd.log" 2>&1 \
    || { cat "$TMP/clangd.log" >&2; die "clangd reported generated-driver diagnostics"; }
else
  echo "[SKIP] clangd generated-driver check (clangd unavailable)"
fi

echo "[PASS] test_driver"
