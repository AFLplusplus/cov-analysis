#!/usr/bin/env bash
# Regression test: a single failed pass must NOT abort the whole stability run.
#
# Reproduces the reported bug "llvm-profdata merge failed for pass 4" aborting
# the entire `cov-analysis stability` run. We compile a real coverage-instrumented
# binary that simulates the field trigger — a crashing/timed-out input that
# leaves a truncated .profraw behind — and drive stability against it twice:
#
#   Scenario A (CORRUPT_RUN_TAG=run_2/): for that one pass the binary writes ONLY
#     a garbage .profraw and skips its instrumentation flush, so the pass's
#     `llvm-profdata merge` fails outright. The run must skip the pass and still
#     finish (exit 0) with a Stability Report instead of aborting.
#
#   Scenario B (CORRUPT_EVERY=1): every pass gets one garbage .profraw alongside
#     the valid ones. The per-pass merge must tolerate it (--failure-mode=all)
#     and report the deterministic target as perfectly stable.
#
# Gated on clang/llvm-cov/llvm-profdata; skips cleanly when unavailable.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)

# ── toolchain gate ───────────────────────────────────────────────────────────
source ./cov-analysis
set +e   # sourcing cov-analysis enables `set -e`; we capture exit codes by hand
CLANG="$(detect_clang || true)"
if test -z "$CLANG" \
   || ! find_tool llvm-cov >/dev/null 2>&1 \
   || ! find_tool llvm-profdata >/dev/null 2>&1; then
  echo "[SKIP] stability resilience test (need clang/llvm-cov/llvm-profdata)"
  echo "[PASS] test_stability_resilience (skipped)"
  exit 0
fi

# ── a coverage binary that can corrupt its own .profraw on demand ────────────
SRC="$TMP/profcorrupt.c"
cat > "$SRC" <<'CSRC'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Expand the single %p in an LLVM_PROFILE_FILE template to our pid. */
static void resolve(const char *tmpl, char *out, size_t cap) {
  size_t o = 0;
  for (size_t i = 0; tmpl[i] && o + 16 < cap; i++) {
    if (tmpl[i] == '%' && tmpl[i + 1] == 'p') {
      o += snprintf(out + o, cap - o, "%d", (int)getpid());
      i++;
    } else {
      out[o++] = tmpl[i];
    }
  }
  out[o] = '\0';
}

static void write_blob(const char *path) {
  FILE *f = fopen(path, "wb");
  if (f) { fputs("GARBAGE-NOT-A-PROFRAW", f); fclose(f); }
}

int main(int argc, char **argv) {
  /* exercise a few lines so valid profiles carry real, stable coverage */
  volatile int x = argc;
  for (int i = 1; i < argc; i++) x += (int)argv[i][0];

  const char *prof = getenv("LLVM_PROFILE_FILE");
  if (!prof) return 0;

  /* Whole-pass failure: overwrite our own .profraw with garbage and skip the
     instrumentation flush, so this pass holds only unparseable profiles —
     exactly what a crash mid-write leaves behind. */
  const char *tag = getenv("CORRUPT_RUN_TAG");
  if (tag && *tag && strstr(prof, tag)) {
    char own[4096];
    resolve(prof, own, sizeof own);
    write_blob(own);
    _exit(0);
  }

  /* One extra garbage .profraw next to the valid one, on every pass. */
  if (getenv("CORRUPT_EVERY")) {
    char dir[4096];
    snprintf(dir, sizeof dir, "%s", prof);
    char *s = strrchr(dir, '/');
    if (s) *s = '\0'; else strcpy(dir, ".");
    char side[4096];
    snprintf(side, sizeof side, "%s/corrupt-%d.profraw", dir, (int)getpid());
    write_blob(side);
  }

  return x ? 0 : 0;
}
CSRC

COV="$TMP/cov"
"$CLANG" -O0 -g -fprofile-instr-generate -fcoverage-mapping "$SRC" -o "$COV" \
  2>"$TMP/cc.log" || { cat "$TMP/cc.log" >&2; die "could not compile coverage binary"; }
test -x "$COV" || die "coverage binary not produced"

# ── AFL fixture: a few deterministic queue inputs ────────────────────────────
AFL="$TMP/out"; mkdir -p "$AFL/queue"
printf 'FAILS' > "$AFL/queue/id:000000,time:0,src:000"
printf 'hello' > "$AFL/queue/id:000001,time:0,src:000"
printf 'world' > "$AFL/queue/id:000002,time:0,src:000"

# ── Scenario A: a fully failed pass must be skipped, not abort the run ────────
out=$(CORRUPT_RUN_TAG='run_2/' bash ./cov-analysis stability -d "$AFL" -e "$COV @@" 2>&1)
rc=$?
assert_eq "$rc" "0" "scenario A: a failed pass must not abort the whole run"
printf '%s\n' "$out" | grep -qi 'skip' \
  || die "scenario A: expected a 'skipping' notice for the failed pass; got:
$out"
printf '%s\n' "$out" | grep -q 'Stability Report' \
  || die "scenario A: expected a Stability Report after skipping the failed pass; got:
$out"
echo "[PASS] scenario A: failed pass skipped, run completes"

# ── Scenario B: per-pass merge must tolerate a single corrupt profraw ────────
out=$(CORRUPT_EVERY=1 bash ./cov-analysis stability -d "$AFL" -e "$COV @@" 2>&1)
rc=$?
assert_eq "$rc" "0" "scenario B: a corrupt profraw must not fail the pass merge"
printf '%s\n' "$out" | grep -q 'perfectly stable' \
  || die "scenario B: expected a perfectly-stable result for a deterministic target; got:
$out"
echo "[PASS] scenario B: corrupt profraw tolerated by per-pass merge"

echo "[PASS] test_stability_resilience"
