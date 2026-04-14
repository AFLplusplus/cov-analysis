# afl-cov - AFL++ Fuzzing Code Coverage

Version: 1.0.0

- [Introduction](#introduction)
- [Prerequisites](#prerequisites)
- [Workflow](#workflow)
  - [Step 1: Build a Coverage Binary](#step-1-build-a-coverage-binary)
  - [Step 2: Generate Coverage Report](#step-2-generate-coverage-report)
  - [Parallelized AFL Execution](#parallelized-afl-execution)
- [Usage Information](#usage-information)
- [License](#license)

## Introduction

`afl-cov` uses test case files produced by [AFL++](https://github.com/AFLplusplus/AFLplusplus) to generate **LLVM source-based code coverage** reports. It replays the entire corpus (queue, crashes, and timeouts) through a coverage-instrumented binary, merges the raw profiles, and produces HTML, text, and JSON reports via `llvm-profdata` and `llvm-cov`.

This is a rewrite of the original afl-cov. Key changes in 1.0.0:
- Replaced gcov/lcov/genhtml with LLVM source-based coverage (`-fprofile-instr-generate`, `llvm-profdata`, `llvm-cov`) - faster, more accurate under optimization
- Rewritten in bash (was Python)
- `afl-cov-build.sh` now emits a ready-to-use `coverage_driver.c` for `LLVMFuzzerTestOneInput` harnesses

## Prerequisites

- `clang` (any version down to 11)
- `llvm-profdata` and `llvm-cov` (matching the clang version; auto-detected)
- AFL++ (`afl-fuzz`) - only needed to produce the corpus, not to run `afl-cov`

## Workflow

### Step 1: Build a Coverage Binary

Use `afl-cov-build.sh` to set the correct compiler flags and build your target:

```bash
# Set up a coverage build (run once per build step)
cd /path/to/project-cov/
afl-cov-build.sh ./configure --disable-shared
afl-cov-build.sh make -j$(nproc)
```

`afl-cov-build.sh` sets:
```
CC=clang  CXX=clang++
CFLAGS="-fprofile-instr-generate -fcoverage-mapping -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1"
LDFLAGS="-fprofile-instr-generate"
```

**Important:** `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1` must match what was used during fuzzing - it disables the same checksums/HMACs that AFL++ bypassed.

#### For `LLVMFuzzerTestOneInput` harnesses

Generate a replay driver and link it against your coverage-instrumented library:

```bash
afl-cov-build.sh --driver -o coverage_driver.c
clang -fprofile-instr-generate -fcoverage-mapping \
  -c coverage_driver.c -o coverage_driver.o
clang -fprofile-instr-generate \
  coverage_driver.o -L./build -ltarget -o cov
```

The driver loops over all file arguments, calls `LLVMFuzzerTestOneInput` for each, and installs a crash handler that flushes profiling data so crashing inputs still contribute to the report.

### Step 2: Generate Coverage Report

```bash
cd /path/to/project-cov/
afl-cov -d /path/to/afl-fuzz-output/ -e "./cov @@"
```

`afl-cov` will:
1. Replay all `queue/id:*` files in batch (fast)
2. Replay `crashes/id:*` and `timeouts/id:*` one-by-one with a timeout
3. Merge `.profraw` profiles with `llvm-profdata`
4. Generate reports in `/path/to/afl-fuzz-output/cov/`

Output:
```
/path/to/afl-fuzz-output/cov/
  html/index.html     ← browse this for annotated source coverage
  text/               ← text format, suitable for automated analysis
  summary.txt         ← per-file line/branch/function percentages
  coverage.json       ← machine-readable export
  coverage.profdata   ← merged profile (baseline for iterative improvement)
```

For stdin-based targets (binary reads from stdin, no file argument):

```bash
afl-cov -d /path/to/afl-fuzz-output/ -e "./target"
```

### Parallelized AFL Execution

For parallel AFL runs (`afl-fuzz -o sync_dir`), point `-d` at the top-level sync directory. `afl-cov` automatically discovers all fuzzer instance subdirectories:

```bash
afl-cov -d /path/to/sync_dir/ -e "./cov @@"
```

## Usage Information

```
Usage: afl-cov [options]

Required:
  -d <dir>    AFL++ fuzzing output directory
  -e <cmd>    Coverage command. Use @@ as input file placeholder.
              Omit @@ to feed input via stdin instead.

Optional:
  -o <dir>           Report output directory (default: <afl-dir>/cov)
  -T <secs>          Timeout for crash/timeout replay (default: 5)
  --ignore-regex <r> Filename regex to exclude from llvm-cov reports
                     (default: /usr/include/)
  -v                 Verbose output
  -q                 Quiet mode
  -V                 Print version and exit
  -h, --help         Print this help and exit
```

### afl-cov-build.sh

```
afl-cov-build.sh <build-command> [args...]   # build mode
afl-cov-build.sh --driver [-o output.c]      # emit coverage_driver.c
```

### afl-stat.sh

Show statistics for a running or completed AFL campaign:

```bash
afl-stat.sh /path/to/afl-fuzz-output/
```

## License

`afl-cov` is released under the **GNU Affero General Public License 3.0**.
