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

# A batch is one process, so an outer timeout can only kill the whole batch.
# The driver's own per-input alarm must name the input that hung, carry on with
# the rest of the batch, and leave the exit status alone.
cat > "$TMP/harness_hang.c" <<'EOF'
#include <stddef.h>
#include <unistd.h>
static volatile int sink;
int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size) {
  if (size > 0 && data[0] == 'H') { for (;;) sleep(1); }
  sink += (int)size;
  return 0;
}
EOF
"$CLANG" -fprofile-instr-generate -fcoverage-mapping "$DRIVER" "$TMP/harness_hang.c" \
  -o "$TMP/cov3" || die "hanging harness compilation failed"
printf a > "$TMP/in1"
printf H > "$TMP/in2"
printf c > "$TMP/in3"
: > "$TMP/slow.txt"
out=$(COV_INPUT_TIMEOUT=1 COV_TIMEOUT_LOG="$TMP/slow.txt" \
  LLVM_PROFILE_FILE="$TMP/hang.profraw" timeout 60 "$TMP/cov3" \
  "$TMP/in1" "$TMP/in2" "$TMP/in3" 2>&1)
rc=$?
assert_eq "$rc" "0" "a timed-out input must not change the driver's exit status: $out"
printf '%s\n' "$out" | grep -q "timeout after 1s: $TMP/in2" \
  || die "the driver did not name the input that hung: $out"
n=$(printf '%s\n' "$out" | grep -c '^Running: ')
assert_eq "$n" "3" "the driver must carry on with the rest of the batch: $out"
assert_eq "$(cat "$TMP/slow.txt")" "$TMP/in2" "the driver did not log the input that hung"
test -s "$TMP/hang.profraw" || die "a batch with a timed-out input wrote no profile"
"$PROFDATA" merge -sparse "$TMP/hang.profraw" -o "$TMP/hang.profdata" \
  || die "the profile written after a per-input timeout is invalid"
echo "[PASS] per-input deadline inside a batch"

# Without COV_INPUT_TIMEOUT nothing is armed and no alarm interferes.
out=$(LLVM_PROFILE_FILE="$TMP/noalarm.profraw" "$TMP/cov3" "$TMP/in1" "$TMP/in3" 2>&1)
assert_eq "$?" "0" "the driver must run unbounded without COV_INPUT_TIMEOUT: $out"
printf '%s\n' "$out" | grep -q '0 timed out' \
  || die "an unbounded run must report no timeouts: $out"

# LLVM_PROFILE_FILE keeps the profiling runtime from dropping a default.profraw
# into the repository at exit.
out=$(LLVM_PROFILE_FILE="$TMP/sig.profraw" "$TMP/cov" --printsignature 2>&1)
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
