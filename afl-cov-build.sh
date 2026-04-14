#!/bin/bash
#
# afl-cov-build.sh - Build a target with LLVM source-based coverage instrumentation
#
# Usage:
#   afl-cov-build.sh <build-command> [args...]
#   afl-cov-build.sh --driver [-o output.c]
#
# The first form sets LLVM coverage flags and runs the build command.
# The second form emits coverage_driver.c for LLVMFuzzerTestOneInput harnesses.

VERSION="0.8.0"

usage() {
  cat << 'EOF'
Syntax: afl-cov-build.sh <build-command> [args...]
        afl-cov-build.sh --driver [-o output.c]

Build mode:
  Sets CC/CXX/CFLAGS/CXXFLAGS/LDFLAGS for LLVM source-based coverage and
  runs the given build command. Must be run once per build step, e.g.:
    afl-cov-build.sh ./configure --disable-shared
    afl-cov-build.sh make -j$(nproc)

  Set CC/CXX environment variables to override the auto-detected clang.

Driver mode (--driver):
  Emits coverage_driver.c source to stdout (or to -o FILE).
  Use this for LLVMFuzzerTestOneInput harnesses to replay corpus files.
  Example:
    afl-cov-build.sh --driver -o coverage_driver.c
    clang -fprofile-instr-generate -fcoverage-mapping \
      coverage_driver.c -L./build -ltarget -o cov

Options:
  -h, --help    Show this help
  -V            Print version and exit
EOF
}

emit_driver() {
  cat << 'DRIVER_EOF'
/* coverage_driver.c - Replay driver for LLVMFuzzerTestOneInput harnesses.
 * Reads files from command-line arguments and calls LLVMFuzzerTestOneInput.
 * Crash handler flushes coverage data on signals so crashing inputs still
 * contribute to the report.
 *
 * Compile and link example:
 *   clang -fprofile-instr-generate -fcoverage-mapping \
 *     -c coverage_driver.c -o coverage_driver.o
 *   clang -fprofile-instr-generate \
 *     coverage_driver.o -L./build -ltarget -o cov
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/types.h>

int LLVMFuzzerInitialize(int *argc, char ***argv) __attribute__((weak));
int LLVMFuzzerTestOneInput(const unsigned char*, size_t);

extern int __llvm_profile_write_file(void);

static void crash_handler(int sig) {
    __llvm_profile_write_file();
    fprintf(stderr, "ERROR: Coverage gathering aborted because of a crash!\n");
    raise(sig);
}

__attribute__((constructor))
static void install_crash_handlers(void) {
    const int sigs[] = { SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTERM };
    struct sigaction sa = {
        .sa_handler = crash_handler,
        .sa_flags   = SA_RESETHAND,
    };
    sigemptyset(&sa.sa_mask);
    for (int i = 0; i < (int)(sizeof(sigs) / sizeof(sigs[0])); i++)
        sigaction(sigs[i], &sa, NULL);
}

int main(int argc, char **argv) {
    if (LLVMFuzzerInitialize) {
        fprintf(stderr, "Running LLVMFuzzerInitialize ...\n");
        LLVMFuzzerInitialize(&argc, &argv);
    }

    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (f) {
            fseek(f, 0, SEEK_END);
            long len = ftell(f);
            if (len > 0) {
                fseek(f, 0, SEEK_SET);
                unsigned char *buf = (unsigned char *)malloc((size_t)len);
                if (buf) {
                    size_t n_read = fread(buf, 1, (size_t)len, f);
                    if (n_read > 0) {
                        fprintf(stderr, "Running: %s (%d/%d) %zu bytes\n",
                                argv[i], i, argc - 1, n_read);
                        LLVMFuzzerTestOneInput((const unsigned char*)buf, n_read);
                    } else {
                        fprintf(stderr, "Error: Read failed for %s\n", argv[i]);
                    }
                    free(buf);
                }
            }
            fclose(f);
        }
    }

    fprintf(stderr, "Done.\n");
    return 0;
}
DRIVER_EOF
}

# ── argument handling ────────────────────────────────────────────────────────

test -z "$1" && { usage; exit 1; }
test "$1" = "-h" -o "$1" = "--help" && { usage; exit 0; }
test "$1" = "-V" && { echo "afl-cov-build.sh-$VERSION"; exit 0; }

if test "$1" = "--driver"; then
  shift
  if test "$1" = "-o"; then
    test -z "$2" && { echo "Error: -o requires a filename" >&2; exit 1; }
    emit_driver > "$2"
    echo "[+] coverage_driver.c written to: $2" >&2
  else
    emit_driver
  fi
  exit 0
fi

# ── build mode ───────────────────────────────────────────────────────────────

# Refuse to run if an AFL++ compiler is already set
echo " $CC $CXX" | grep -q afl && { echo "Error: AFL++ compiler is set." >&2; exit 1; }

# Auto-detect clang if CC/CXX not set
if test -z "$CC"; then
  if command -v clang >/dev/null 2>&1; then
    export CC=clang
    export CXX=clang++
  else
    for ver in 20 19 18 17 16 15 14 13 12 11; do
      if command -v "clang-$ver" >/dev/null 2>&1; then
        export CC="clang-$ver"
        export CXX="clang++-$ver"
        break
      fi
    done
  fi
fi

test -z "$CC" && { echo "Error: clang not found. Install clang or set CC/CXX." >&2; exit 1; }
echo "[+] Using compiler: $CC / $CXX" >&2

export CFLAGS="-fprofile-instr-generate -fcoverage-mapping -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="$CFLAGS"
export LDFLAGS="-fprofile-instr-generate"

exec "$@"
