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
  echo "[SKIP] persistent-state stability test (clang unavailable)"
  exit 0
fi
export CC="$CLANG"
if ! find_tool llvm-profdata >/dev/null 2>&1 || ! find_tool llvm-cov >/dev/null 2>&1; then
  echo "[SKIP] persistent-state stability test (matching LLVM tools unavailable)"
  exit 0
fi

bash ./cov-analysis driver -o "$TMP/driver.c" >/dev/null 2>&1

cat > "$TMP/counter.c" <<'EOF'
#include <stddef.h>
#include <stdio.h>
static int calls;
int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size) {
  (void)data; (void)size;
  if (calls++ % 2)
    puts("odd call");
  return 0;
}
EOF
cat > "$TMP/lazy.c" <<'EOF'
#include <stddef.h>
#include <stdlib.h>
static int *table;
int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size) {
  if (!table)
    table = calloc(256, sizeof(*table));
  if (size > 0)
    table[data[0]] = 1;
  return 0;
}
EOF
for h in counter lazy; do
  "$CLANG" -fprofile-instr-generate -fcoverage-mapping "$TMP/driver.c" "$TMP/$h.c" \
    -o "$TMP/$h" || die "building the $h harness failed"
done

mkdir -p "$TMP/corpus"
printf a > "$TMP/corpus/a"
printf b > "$TMP/corpus/b"
printf c > "$TMP/corpus/c"

out=$(bash ./cov-analysis stability -d "$TMP/corpus" -e "$TMP/counter @@" 2>&1)
rc=$?
assert_eq "$rc" "0" "stability run failed: $out"
printf '%s\n' "$out" | grep -q 'Unstable coverage detected' \
  || die "a harness that branches on a static call counter was called stable: $out"
printf '%s\n' "$out" | grep -q 'counter.c:7$' \
  || die "the line that depends on the call counter was not named: $out"
printf '%s\n' "$out" | grep -q 'Replay *: each input 5 times in one process' \
  || die "the start of the run must say how inputs are replayed: $out"
printf '%s\n' "$out" | grep -q '^Runs *: 8$' \
  || die "an unstable harness must extend the run to 8 passes: $out"
printf '%s\n' "$out" | grep -q '^Replay *: each input in 2 processes of 5 runs, the first run of each unrecorded$' \
  || die "the report must describe the extended run: $out"
echo "[PASS] state carried between executions is reported as instability"

out=$(bash ./cov-analysis stability -d "$TMP/corpus" -e "$TMP/lazy @@" 2>&1)
rc=$?
assert_eq "$rc" "0" "stability run failed: $out"
printf '%s\n' "$out" | grep -q 'perfectly stable' \
  || die "one-time lazy initialization was reported as instability: $out"
echo "[PASS] one-time initialization is not reported as instability"

out=$(bash ./cov-analysis stability -d "$TMP/corpus" -e "$TMP/counter @@" --isolated 2>&1)
rc=$?
assert_eq "$rc" "0" "stability --isolated run failed: $out"
printf '%s\n' "$out" | grep -q 'perfectly stable' \
  || die "--isolated must replay every execution in a fresh process: $out"
echo "[PASS] --isolated replays every execution in a fresh process"

cat > "$TMP/old_driver.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int LLVMFuzzerTestOneInput(const unsigned char*, size_t);
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--printsignature") == 0) {
        printf("###SIGNATURE_LLVMFUZZERTESTONEINPUT_COVERAGE###\n");
        return 0;
    }
    for (int i = 1; i < argc; i++) {
        unsigned char buf[64];
        FILE *f = fopen(argv[i], "rb");
        size_t n;
        if (!f) return 2;
        n = fread(buf, 1, sizeof(buf), f);
        fclose(f);
        LLVMFuzzerTestOneInput(buf, n);
    }
    return 0;
}
EOF
"$CLANG" -fprofile-instr-generate -fcoverage-mapping "$TMP/old_driver.c" "$TMP/counter.c" \
  -o "$TMP/old_counter" || die "building the old-driver harness failed"
out=$(bash ./cov-analysis stability -d "$TMP/corpus" -e "$TMP/old_counter @@" 2>&1)
rc=$?
assert_eq "$rc" "0" "stability run on an old driver failed: $out"
printf '%s\n' "$out" | grep -q 'cov-analysis driver' \
  || die "an old driver must be told to rebuild with the current driver: $out"
printf '%s\n' "$out" | grep -q 'perfectly stable' \
  || die "an old driver must fall back to fresh-process replay: $out"
echo "[PASS] a driver without in-process replay falls back and says so"

echo "[PASS] test_stability_persistent_state"
