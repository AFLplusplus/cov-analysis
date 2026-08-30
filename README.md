# cov-analysis - Fuzzing Code Coverage for AFL++, libFuzzer, libafl, and honggfuzz

![CI](https://github.com/vanhauser-thc/cov-analysis/actions/workflows/ci.yml/badge.svg)

Replacing `afl-cov` and `libfuzzer-cov` with modern coverage gathering and great features!

Version: 1.3-dev

- [Introduction](#introduction)
- [Prerequisites](#prerequisites)
- [Supported Fuzzers](#supported-fuzzers)
- [Workflow](#workflow)
  - [Step 1: Build a Coverage Binary](#step-1-build-a-coverage-binary)
  - [Step 2: Generate Coverage Report](#step-2-generate-coverage-report)
    - [Multiple harnesses in one run](#multiple-harnesses-in-one-run)
    - [Replaying where the corpus lives](#replaying-where-the-corpus-lives)
  - [Step 3: Diff Two Coverage Reports](#step-3-diff-two-coverage-reports)
  - [Step 4: Identifying unstable code lines](#step-4-identifying-unstable-code-lines)
  - [Step 5: Search which inputs reach a line](#step-5-search-which-inputs-reach-a-line)
  - [Parallelized AFL Execution](#parallelized-afl-execution)
- [Usage Information](#usage-information)
  - [cov-analysis report (default)](#cov-analysis-report-default)
  - [cov-analysis build](#cov-analysis-build)
  - [cov-analysis driver](#cov-analysis-driver)
  - [cov-analysis diff](#cov-analysis-diff)
  - [cov-analysis stability](#cov-analysis-stability)
  - [cov-analysis search](#cov-analysis-search)
- [License](#license)

## Introduction

`cov-analysis` generates **LLVM source-based code coverage** reports from a fuzzing corpus. It auto-detects the on-disk layout used by [AFL++](https://github.com/AFLplusplus/AFLplusplus) (queue/crashes/timeouts directories, single or parallel), libFuzzer and libafl (flat corpus dir plus `crash-*`/`leak-*`/`oom-*` artifacts), and honggfuzz (flat corpus plus `SIG*.fuzz` crash files). It replays each input through a coverage-instrumented binary, merges the raw profiles, and produces HTML, text, and JSON reports via `llvm-profdata` and `llvm-cov`.

This is a rewrite of the original cov-analysis. Key changes in 1.0:
- New: diff reports comparing coverage between two runs
- New: stability analysis identifying source lines with non-deterministic hit counts
- Replaced gcov/lcov/genhtml with LLVM source-based coverage (`-fprofile-instr-generate`, `llvm-profdata`, `llvm-cov`) - faster, more accurate under optimization
- `cov-analysis build` sets compiler flags and builds the target; `cov-analysis driver` emits a ready-to-use `coverage_driver.c` for `LLVMFuzzerTestOneInput` harnesses
- `cov-analysis diff` generates an HTML diff report comparing coverage between two JSON exports
- Rewritten in bash (was Python)

The coverage reports can be augmented with harness reachability information from [fuzz-reachability](https://github.com/AFLplusplus/fuzz-reachability)

## Prerequisites

- Bash
- `clang` (any version down to 11)
- `llvm-profdata` and `llvm-cov` — auto-detected to match the selected clang
  version. When a versioned compiler is chosen (e.g. `CC=clang-22`, or the
  default `clang` reports version 22), the matching `llvm-profdata-22` /
  `llvm-cov-22` are used so the raw profiles merge without a version mismatch.
- GNU findutils (`find` and `xargs`) and either GNU coreutils or uutils coreutils
  (`timeout`, `mktemp`, `realpath`, `mv`, `sort`, `tr`, and `wc`). Timed replays
  send `TERM`, escalate to `KILL` after one second, and clean up the spawned
  process group.
- Python 3 for `report` (it derives the per-function source list), `diff`,
  and the macro-definition split in `stability` (skipped if absent there).
- GNU awk (`gawk`) for `stability`.
- AFL++ (`afl-fuzz`), libafl, libfuzzer, Honggfuzz, ... - only needed to produce the corpus, not to run `cov-analysis`

## Supported Fuzzers

| Fuzzer     | Detected by                                | Input files replayed                                                          |
|------------|--------------------------------------------|-------------------------------------------------------------------------------|
| AFL++      | queue/crashes/timeouts under `<dir>` or a worker | `queue/id:*`, `crashes/id:*`, `hangs/id:*`                            |
| libFuzzer  | flat directory of files, no `queue/`       | all files except `crash-*`/`leak-*`/`oom-*`/`timeout-*`/`slow-unit-*`        |
| libafl     | flat directory of files, no `queue/`       | all files except `crash-*`/`leak-*`/`oom-*`/`timeout-*`/`slow-unit-*`        |
| honggfuzz  | flat directory of files, no `queue/`       | all files except `SIG*.fuzz` and `HONGGFUZZ.REPORT.TXT`                       |

Only regular files are selected. Directories and symlinks are never counted or
replayed. For libFuzzer, libafl and honggfuzz, crash-like files are replayed
under the `-T` hard deadline so a hanging input cannot stall the run.

Queue and corpus inputs have their own deadline, `--queue-timeout`. Its default
is derived from the campaign: the largest `slowest_exec_ms` across the AFL++
`fuzzer_stats` files, rounded up to a whole second and multiplied by 5 (at
least 5s), because the coverage binary has no forkserver, runs `-O1` with
counters and writes a profile per exec. A layout that carries no `fuzzer_stats`
gets 60s. Inputs that hit the deadline are listed in `<-o>/slow_inputs.txt`:
a corpus entry that does not terminate under coverage instrumentation is a
finding in its own right.

Inputs are always handed to the target as absolute paths, so a harness that
changes its working directory (a sandbox `chdir()`, for example) still finds
them. Every replay is accounted for: `report` and `stability` print how many
inputs replayed cleanly, failed, or hit the deadline, and `report` refuses to
publish a report when more of the queue failed than `--max-replay-failures`
allows — a target that never processed its inputs produces a wrong number, not
a low one.

Override auto-detection with `--layout afl|flat`.

## Workflow

Note: `cov-analysis` uses the `TMPDIR` environment variable if present.

### Step 1: Build a Coverage Binary

Use `cov-analysis build` to set the correct compiler flags and build your target:

```bash
# Set up a coverage build (run once per build step)
cd /path/to/project-cov/
cov-analysis build ./configure --disable-shared
cov-analysis build make -j$(nproc)
```

`cov-analysis build` resolves a Clang pair and appends these options to the
caller's existing values:
```
CC=clang  CXX=clang++
CFLAGS/CXXFLAGS+=" -fprofile-instr-generate -fcoverage-mapping"
CPPFLAGS+=" -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1"
LDFLAGS+=" -fprofile-instr-generate"
```

An explicitly supplied `CC` or `CXX` is preserved. The missing counterpart is
derived for unversioned, versioned, and absolute-path Clang names. Set both
variables for a custom compiler wrapper that cannot be paired safely.

**Important:** `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1` must match what was used during fuzzing - it disables the same checksums/HMACs that AFL++ bypassed.

#### For `LLVMFuzzerTestOneInput` harnesses

Generate a replay driver and link it against your coverage-instrumented library:

```bash
cov-analysis driver -o coverage_driver.c
clang -fprofile-instr-generate -fcoverage-mapping \
  -c coverage_driver.c -o coverage_driver.o
clang -fprofile-instr-generate \
  coverage_driver.o -L./build -ltarget -o cov
```

The driver loops over all file arguments, calls `LLVMFuzzerTestOneInput` for
each, and installs a crash handler that attempts to flush profiling data before
re-raising the original signal. This is best effort:
`__llvm_profile_write_file()` is not async-signal-safe and can fail after severe
memory corruption.

### Step 2: Generate Coverage Report

This step produces an `llvm-cov` coverage report with regions and branches:

<img align="left" src="https://raw.githubusercontent.com/AFLplusplus/cov-analysis/main/report-overview.png" alt="report overview">

<img align="left" src="https://raw.githubusercontent.com/AFLplusplus/cov-analysis/main/report-detail.png" alt="report detail">

```bash
cd /path/to/project-cov/
cov-analysis -d /path/to/afl-fuzz-output/ -e "./cov @@"
```

To replay coverage with multiple workers, add `-t`:

```bash
cov-analysis -d /path/to/afl-fuzz-output/ -e "./cov @@" -t 8
```

`cov-analysis` will for AFL++:
1. Replay all `queue/id:*` files, in batch when the binary allows it (see `--batch`)
2. Replay `crashes/id:*` and `hangs/id:*` one-by-one with a timeout
3. Merge `.profraw` profiles with `llvm-profdata`
4. Generate reports in `/path/to/afl-fuzz-output/cov/`

For libfuzzer/libafl/Honggfuzz `cov-analysis` will:
1. Replay all files in the directory
2. Crash files are replayed one-by-one with a timeout

Output:
```
/path/to/afl-fuzz-output/cov/
  .cov-analysis-report ← ownership marker for safe replacement
  html/index.html     ← browse this for annotated source coverage
  text/               ← text format, suitable for automated analysis
  summary.txt         ← per-file line/branch/function percentages
  gaps.txt            ← uncovered code ranked by ABSOLUTE uncovered regions
  coverage.json       ← machine-readable export
  coverage.profdata   ← merged profile (baseline for iterative improvement)
  slow_inputs.txt     ← only when inputs hit the replay deadline: which ones
```

`gaps.txt` answers "where is the most uncovered code" without post-processing.
It ranks files by absolute uncovered regions — a 3,553-region file at 4% holds
far more uncovered code than an 85-region file at 0%, which a percentage sort
gets backwards — and then lists every function with no coverage at all, ranked
the same way. Its numbers come from `llvm-cov report -show-functions` and match
`summary.txt`. The top entries are printed at the end of a report run. With
`--reachability` the function list is split into the actionable gap (reachable
or unclassified) and expected dead code (statically unreachable), and files are
ranked by their *reachable* uncovered regions.

Report publication is transactional. All artifacts are generated and validated
in a sibling staging directory on the same filesystem, including optional
reachable-only metrics and annotations. The prior report is moved aside only
for the final rename and is restored if publication fails. A second successful
run copies the prior `coverage.json` into the staged report as
`coverage_old.json`.

A non-empty output directory is replaceable only when it contains the
`.cov-analysis-report` ownership marker. New and empty destinations are allowed.
To migrate a complete report created by an older pre-marker release, run the
new report once with `--migrate-existing-report`. The option validates the old
HTML, text, summary, JSON, and profile artifacts; it never adopts an arbitrary
directory. A failed migration run leaves the old report unchanged.

For stdin-based targets (binary reads from stdin, no file argument):

```bash
cov-analysis -d /path/to/afl-fuzz-output/ -e "./target"
```

Simple `-e` commands retain automatic binary discovery. Use `--binary` when the
shell command contains a quoted binary path, `env`, a wrapper, or other shell
syntax; that explicit path is validated independently and used for driver
detection and all LLVM operations:

```bash
cov-analysis -d out -e 'env MODE=cov "/opt/my app/cov" @@' \
  --binary "/opt/my app/cov"
cov-analysis -d out -e './coverage-wrapper ./cov @@' --binary ./cov
```

Every `-e` string is executed by Bash. Trailing, embedded, and omitted `@@`
therefore accept the same shell language.

#### libFuzzer corpus

```bash
cov-analysis -d /path/to/libfuzzer-corpus/ -e "./cov @@"
```

Corpus files are replayed in batch mode automatically when the selected binary
carries the cov-analysis driver signature. A libFuzzer binary carries no such
signature, so it defaults to one process per input — but it does take several
input files on argv, so `--batch 128` applies the same amortisation and is worth
it on any corpus large enough to notice:

```bash
cov-analysis -d /path/to/libfuzzer-corpus/ -e "./fuzzer @@" --binary ./fuzzer \
             --batch 128
```

Because a libFuzzer binary has no per-input alarm, an input that does not
terminate costs its whole batch the coverage when the deadline kills it. Re-run
with `--batch 0` to isolate one, guided by `<-o>/slow_inputs.txt`.

If your libFuzzer run used `-artifact_prefix=./crashes/`, point a second run at
that directory to cover crash inputs too — or move artifacts into the corpus dir
beforehand.

#### honggfuzz workspace

```bash
cov-analysis -d /path/to/hfuzz-workdir/ -e "./cov @@"
```

`SIG*.fuzz` crash files are replayed under the `-T` timeout. The `HONGGFUZZ.REPORT.TXT` metadata file is ignored automatically.

#### Cross-referencing static reachability

If you have run the companion [fuzz-reachability](https://github.com/AFLplusplus/fuzz-reachability)
analyzer, pass its output with `--reachability` to tell apart coverage gaps that
are worth chasing from dead weight you can safely ignore:

```bash
cov-analysis -d /path/to/afl-fuzz-output/ -e "./cov @@" \
  --reachability /path/to/reachability/test.json
```

`--reachability` accepts the analyzer's JSON report, its output directory, or
a single SanitizerCoverage allow/ignore `.txt` list. When a directory is
passed, a `reachability.json` inside it is preferred (it carries richer data —
indirect-call confidence, file/line, both mangled and demangled names) over
the `reached.txt` / `not_reached.txt` lists, which are used only as a
fallback when no `reachability.json` is present. The normal `llvm-cov` HTML
and text reports are annotated **in place** (no separate report). In the
HTML file view each function's lines are tinted:

- **covered** — keeps `llvm-cov`'s usual coloring
- **amber** — statically *reachable* but never reached (the actionable gap),
  shaded by the analyzer's per-function `confidence` (JSON mode only; the txt
  lists carry no confidence, so they always render the plain shade): darkest
  amber for `high` (a direct edge, or no confidence data at all), a lighter
  amber for `medium` (reachable only through an indirect call with value-flow
  evidence), and the lightest amber for `low` (an indirect call matched only
  by type — the likely-spurious surface of the over-approximation)
- **dark grey** — statically *unreachable*, so it is expected to stay
  uncovered — ignore it
- **purple** — covered yet flagged unreachable (a static-analysis anomaly worth
  a look, since the analyzer should never under-reports, please open an issue to report bugs)

The HTML `index.html` gains a tally banner. The text source view (`text/`) gets
a per-line marker column (`U` unreachable, `R` reachable-but-unreached,
`A` anomaly), and `summary.txt` gains a reachability tally plus the explicit
list of reachable-but-not-reached functions to go after.

> **Matching mangling schemes join by exact name; a mismatch falls back to
> `(file, line)`.** Build the reachability analysis with the same scheme the
> coverage binary uses — fuzz-reachability's `--mangling` flag — and the
> mangled names are identical on both sides, so the join above hits by exact
> name/`key` directly: `--mangling legacy` for a legacy-mangled coverage
> binary (the default for `cargo-afl`/`ziggy`/`cargo-fuzz` builds), or
> `--mangling v0` for a `-Cinstrument-coverage` coverage binary (which always
> forces Rust's **v0** `_R…` mangling). Rust name/key matching only
> *tolerates drift* within the legacy scheme: the name/`key` join above
> survives the legacy `17h<hash>` disambiguator differing between the
> analyzed build and the coverage build. Under v0, fuzz-reachability's `key`
> equals the raw mangled name — the normalization is inert for v0 — so a
> scheme mismatch (e.g. a legacy-mangled analysis joined against a
> v0-mangled coverage binary) or a v0 disambiguator that drifts between two
> independently-built v0 binaries will not match by name or `key`. When the
> reachability report is the JSON report (not the `.txt` lists) and carries
> `file`/`line` for the function (i.e. the analyzed bitcode has debug info),
> the `(file, line)` fallback used above still classifies it correctly;
> without debug info the function has no fallback and is left `unknown`. See
> fuzz-reachability's README for the full explanation; full v0-aware key
> normalization for the drifting-disambiguator case is a future enhancement
> there, not yet implemented.

**The coverage numbers themselves are recomputed to exclude unreachable
functions.** Normally a function coverage of `5/6` counts a statically-dead
function in the denominator even though the harness can never reach it. With
`--reachability`, the Function / Line / Region / Branch numbers in both
`index.html` and `summary.txt` drop every statically-unreachable function from
the denominators (and numerators), so the percentages reflect only code the
harness can actually reach — e.g. that `5/6` becomes `5/5`. The numbers come
straight from `llvm-cov report -show-functions` (so they match llvm-cov's own
math exactly), re-summed over the reachable set; the unmodified figures remain
in `coverage.json`. With `--reachability` the HTML index is rendered flat
(directory grouping disabled) so its cells can be rewritten reliably.

An explicitly requested reachability report is all-or-nothing. Its input is
parsed before replay starts, and invalid input, per-function metric failure, or
annotation failure returns nonzero without changing the last successful report.
Exit status 0 guarantees the banner, tally, annotations, and reachable-only
metrics are present.

`cov-analysis diff` accepts the same `--reachability` flag; it splits the
"still uncovered functions" list in the diff report into reachable (amber,
actionable) and unreachable (grey, expected dead).

#### Multiple harnesses in one run

A project with more than one harness needs per-harness numbers, the union, and
a way to see which harness covers what. Repeat `-d`/`-e` and `cov-analysis`
produces all three in one command:

```bash
cov-analysis -d out-parser  -e "./cov-parser @@"  --name parser \
             -d out-decoder -e "./cov-decoder @@" --name decoder \
             -o coverage
```

Each `-d` starts a campaign; `-e`, `--binary` and `--name` attach to the
campaign started by the most recent `-d`. A single `-d`/`-e` pair behaves
exactly as before. With two or more, the output directory holds:

```
coverage/
  parser/       ← full report for that campaign, gaps.txt included
  decoder/
  union/        ← full report over every campaign, every binary as its own object
  attribution.txt   ← per file: lines each campaign covered, and lines only it reached
  attribution.html
```

The attribution table answers "which harness covers this file best" and, more
usefully, "which lines would I lose if I dropped this harness" — a file whose
lines are all unique to one campaign is covered by that harness alone.

If the campaign binaries were built from different sources, `cov-analysis` says
so: llvm-cov keeps one coverage mapping per function and silently drops the
ones that differ, so the union would under-report without the warning.

#### Replaying where the corpus lives

Carrying a 32k-file corpus across the network to replay it locally is the slow
way round. `--replay-only` stops after the merged profile, and `--profdata`
renders from one:

```bash
# on the fuzzing box
cov-analysis -d out -e "./cov @@" -o profile --replay-only
# back on your machine, after copying profile/coverage.profdata
cov-analysis --profdata coverage.profdata --binary ./cov -o coverage
```

`--remote` does both halves in one command, copying `cov-analysis` to the host
itself so nothing needs to be installed there:

```bash
cov-analysis --remote fuzzbox -d /fuzz/out -e "/fuzz/cov @@" \
  --binary ./cov -o coverage
```

`-d` and `-e` are paths on the remote host; `--binary` is the matching local
binary used for rendering, and `-o` is required. Only `coverage.profdata` comes
back — never the corpus. The remote working directory is removed on success and
on failure. Pass ssh/scp options with `--ssh-opts "-o Port=2222"`.

`--profdata` is also how you re-render an existing report with a different
`--ignore-regex` or fresh `--reachability` data, without replaying anything.

`--remote` is also immune to version skew: it copies the local script to the
host, so both halves of the run are the same build. For two installations you
compare by hand, `-V` prints the content hash and path of the copy that ran —
two checkouts months apart carry the same version string, and the hash is what
tells them apart.

#### One run at a time per report directory

A run locks its output directory for as long as it holds it. A second run
against the same `-o` is refused, naming the pid of the one that has it; pass
`--force` to take the directory over. The lock and the staging directory live
beside the report as `.<name>.cov-analysis.lock` and
`.<name>.cov-analysis.stage.*` — beside it, because publication is an atomic
rename and a rename cannot cross filesystems.

A killed run leaves its staging directory behind. `--clean` removes the lock
and staging directories that no running `cov-analysis` holds:

```bash
cov-analysis report -o coverage --clean
```

It refuses while a live run holds the directory, and it never deletes a
`.cov-analysis.rollback.*` directory: that one holds the previous report of a
run that died while publishing.

### Step 3: Diff Two Coverage Reports

Compare coverage between two `llvm-cov` JSON exports and generate an HTML diff report:

```bash
cov-analysis diff coverage_old.json coverage_new.json
```

If you use the same output directory for a subsequent run, `cov-analysis`
copies the previous successful `coverage.json` into the staged
`coverage_old.json`, so `cov-analysis diff` works with no arguments.

The report is written to `<report-dir>/coverage_diff.html` and shows:
- Newly covered and no-longer-covered lines per file
- Newly covered and lost functions
- Source code snippets annotated with coverage change

The default is a full report, including unchanged files and their
still-uncovered lines/functions. Add `--only-changed` to omit unchanged files.
Aggregate cards say whether their scope is all files or changed files only.

If the JSON paths are omitted, `cov-analysis diff` defaults to `<report-dir>/coverage_old.json` and `<report-dir>/coverage.json`. Run with no arguments and neither default report present in the current directory, it prints the help instead of an error.

The HTML diff report looks like this:

<img align="left" src="https://raw.githubusercontent.com/AFLplusplus/cov-analysis/main/diff-overview.png" alt="diff overview">
<img align="left" src="https://raw.githubusercontent.com/AFLplusplus/cov-analysis/main/diff-detail.png" alt="diff detail">

### Step 4: Identifying unstable code lines

Ever wondered which source lines cause AFL++ or libafl to report instability in a fuzz target?
The `stability` command identifies them.

```bash
cov-analysis stability -d ../afl/out -e "./cov @@"
cov-analysis stability -d ../afl/out -e "./cov @@" -T 2
```

The denominator is the union of source lines executed at least once across all
successful passes. Lines that are zero or absent in every pass are excluded;
a zero/absent-to-positive transition is included and classified unstable. If no
line executes in any successful pass, stability is `n/a`.

Macro definition lines are reported separately. llvm-cov attributes every macro
expansion to the line of the `#define`, so a macro used from varying call sites
(the field report names `SSH_LOG` at `priv.h:283`) shows up as a single unstable
line in a header, which is not a location anyone can fix. Those lines are listed
under their own heading with the number of expansion sites, leaving the main
list actionable. Use `--exclude-regex` to drop such files from the analysis
altogether.

Every analyzed pass measures the same inputs. An input killed at the `-T`
deadline never writes its profile, so it contributes nothing to that pass —
under `-t` contention a borderline input crosses the deadline in some passes and
not others, and every line only it covers would flip between 0 and N. Such
inputs are excluded from **all** passes and reported as
`Inputs used : K of N`, so the verdict does not depend on `-t`. If no input
survives every pass, the run fails instead of reporting a meaningless number.

This will give you the exact lines that are problematic, e.g.:
```
Stability Report
--------------------------------------------------------
Corpus size : 2 inputs
Runs        : 8
Stability   : 74.0% (91/123 executed lines stable)

~~ Variable-count lines (32 lines):
   Lines with varying hit counts:

  /prg/cov-analysis/tests/unstable.c:35-37
  /prg/cov-analysis/tests/unstable.c:43
  /prg/cov-analysis/tests/unstable.c:46-48
  /prg/cov-analysis/tests/unstable.c:51-52
  /prg/cov-analysis/tests/unstable.c:55-61
  /prg/cov-analysis/tests/unstable.c:64-66
  /prg/cov-analysis/tests/unstable.c:69-70
  /prg/cov-analysis/tests/unstable.c:75-85

[!] Unstable coverage detected.
```

### Step 5: Search which inputs reach a line

Wonder which corpus entries actually exercise a particular source line? The
`search` command replays each input in isolation and reports the ones that
reach `FILE:LINE`:

```bash
cov-analysis search src/parser.c:142 -d ../afl/out -e "./cov @@"
```

Matching input paths are printed to stdout (one per line, sorted) so the result
pipes cleanly; progress and the summary go to stderr:

```
src/parser.c:142 is reachable; scanning...
out/queue/id:000017,...
out/queue/id:000094,...
[+] 2 of 142 inputs reach src/parser.c:142
```

By default only queue/corpus entries are scanned. Add `--crashes` to also scan
crash and timeout inputs, and `-t N` to parallelize:

```bash
cov-analysis search src/parser.c:142 -d ../afl/out -e "./cov @@" --crashes -t 8
```

`--crashes` also works for a crash-only flat directory or AFL++ output tree.
Without it, a crash-only directory correctly reports that no corpus input was
selected.

A fast union pre-check replays the whole corpus once first; `-T` bounds every
selected input in this phase and in the isolated scan. If no input reaches
the line, `search` reports `0 of N` immediately (and tells you whether the line
is merely unreached or not present in the coverage data at all) without the full
per-input scan.

Pipe the reaching inputs straight into another tool:

```bash
cov-analysis search src/parser.c:142 -d ../afl/out -e "./cov @@" | xargs -I{} cp {} ./hits/
```

### Parallelized AFL Execution

For parallel AFL runs (`afl-fuzz -o sync_dir`), point `-d` at the top-level sync directory. `cov-analysis` automatically discovers all fuzzer instance subdirectories:

```bash
cov-analysis -d /path/to/sync_dir/ -e "./cov @@"
```

## Usage Information

### cov-analysis report (default)

```
Usage: cov-analysis [report] [options]

Required:
  -d <dir>    Fuzzing output directory (AFL++, libFuzzer, libafl, or honggfuzz)
  -e <cmd>    Coverage command. Use @@ as input file placeholder.
              Omit @@ to feed input via stdin instead. For a cov-analysis
              driver binary (which reads files, not stdin), @@ is appended
              automatically when omitted.

Optional:
  -o <dir>           Report output directory (default: <afl-dir>/cov)
  -t <num>           Parallel replay workers/forks (default: 1)
  -T <secs>          Timeout for crash/timeout replay (default: 5)
  --queue-timeout <secs>
                     Per-input timeout for queue/corpus replay. Default: derived
                     from the largest slowest_exec_ms in the AFL++ fuzzer_stats
                     files (rounded up to a second, x5, minimum 5s), or 60s when
                     there is none. 0 disables it. Inputs that hit it are listed
                     in <-o>/slow_inputs.txt
  --batch <num>      Replay <num> queue inputs per process instead of one, which
                     amortises the fork, the exec and the profile write each
                     input otherwise pays for. Needs a coverage command ending
                     in @@ and a target that takes several input files on argv.
                     Default: 128 for a cov-analysis driver binary, one input
                     per process otherwise; 0 or 1 forces one per process
  --force            Take over a report directory another run holds
  --clean            Remove the lock and staging directories of <-o> that no
                     running cov-analysis holds, then exit
  --binary <path>    Instrumented binary for LLVM and driver detection;
                     required when -e has quoted paths, wrappers, or shell syntax
  --layout <kind>    Force layout: 'afl' or 'flat' (default: auto-detect)
  --max-replay-failures <pct>
                     Fail the run when more than <pct> percent of the queue
                     inputs did not replay cleanly (default: 99). Crash and
                     timeout inputs are exempt. Use 100 for targets that
                     legitimately exit non-zero for rejected inputs.
  --ignore-regex <r> Filename regex to exclude from llvm-cov reports
                     (default: /usr/include/)
  --reachability <p> Cross-reference fuzz-reachability output (its JSON report,
                     output directory — reachability.json when present, else
                     reached.txt/not_reached.txt — or a sancov allow/ignore
                     .txt list) and annotate the HTML + text reports in
                     place: functions tinted amber=reachable but not
                     reached, dark grey=unreachable,
                     purple=covered yet flagged unreachable; text gets a U/R/A
                     marker column and summary.txt a reachability tally.
                     Any reachability/recompute failure makes report fail.
  --replay-only      Replay and merge, write coverage.profdata into <-o>, and
                     stop without rendering a report
  --profdata <file>  Render from existing profile data instead of replaying a
                     corpus; repeatable, several profiles merge into one report
  --name <name>      Directory name for the campaign started by the last -d
  --remote <host>    Replay on [user@]host and fetch only the merged profile;
                     -d/-e are remote paths, --binary is the local binary
  --ssh-opts <opts>  Options for ssh and scp, e.g. "-o Port=2222"
  --remote-dir <dir> Remote working directory (default: remote mktemp -d)
  --migrate-existing-report
                     Explicitly replace a complete pre-marker report after a
                     successful staged run; arbitrary directories are refused
  -v                 Verbose output
  -q                 Quiet mode
  -V                 Print version and exit
  -h, --help         Print this help and exit
```

### cov-analysis build

```
Usage: cov-analysis build <build-command> [args...]

  Resolves CC/CXX, appends coverage options to existing CFLAGS, CXXFLAGS,
  CPPFLAGS, and LDFLAGS, and runs the given build command.
```

### cov-analysis driver

```
Usage: cov-analysis driver [-o output.c]

  Emits coverage_driver.c source to stdout (or to -o FILE).
  Use this for LLVMFuzzerTestOneInput harnesses to replay corpus files.

  The driver loops over all file arguments, calls LLVMFuzzerTestOneInput
  for each, and makes a best-effort crash-time profile flush before
  re-raising the original signal. The profile writer is not async-signal-safe.

  Input paths are resolved to absolute paths before the harness runs, so a
  harness that changes its working directory still finds them. Unreadable
  inputs are reported on stderr and make the driver exit 2; empty inputs are
  reported but are not an error.

Options:
  -o <file>     Write driver source to FILE instead of stdout
```

### cov-analysis diff

```
Usage: cov-analysis diff [-o <dir>] [--only-changed] [--reachability <p>] [<OLD_JSON> <NEW_JSON>]

  Compare coverage between two llvm-cov JSON exports and generate an
  HTML diff report showing newly covered, lost, and still-uncovered
  lines and functions.

  Defaults to <report-dir>/coverage_old.json and <report-dir>/coverage.json.

  --reachability <p> cross-references fuzz-reachability output (JSON, output
  directory — reachability.json when present, else reached.txt/not_reached.txt
  — or a sancov .txt list) and splits the still-uncovered functions into
  reachable (amber, actionable) vs unreachable (grey, expected dead).
  --only-changed omits unchanged files; the default full report retains them.
```

### cov-analysis stability

```
Usage: cov-analysis stability [options]

  Run each corpus input N times with LLVM coverage, collect per-line hit
  counts, and flag lines where counts vary across runs as "unstable."
  Reports a stability percentage. If instability is found with the default
  4 runs, reruns for a total of 8 to confirm.

  Resilient to flaky passes: a pass whose profiles cannot be collected or
  merged (e.g. a crashing input that left a truncated .profraw behind) is
  skipped and the run continues with the remaining passes, as long as at
  least 2 passes succeed.

  Every analyzed pass measures the same inputs: an input killed at the -T
  deadline writes no profile, so it is excluded from ALL passes and reported.
  The verdict does not depend on -t. If no input survives every pass, the run
  fails instead of reporting a meaningless number.

Required:
  -d <dir>    Fuzzing output directory (AFL++, libFuzzer, libafl, or honggfuzz)
  -e <cmd>    Coverage command. Use @@ as input file placeholder.
              Omit @@ to feed input via stdin instead. For a cov-analysis
              driver binary (which reads files, not stdin), @@ is appended
              automatically when omitted.

Optional:
  -n <num>           Number of runs per corpus pass (default: 4)
  -s <prefix>        Only consider source lines whose file path contains
                     this prefix (e.g. -s src/)
  --exclude-regex <re>
                     Drop source files whose path matches this regex, applied
                     on top of -s (e.g. --exclude-regex '\.h$')
  -t <num>           Parallel replay workers (default: 1)
  -T <secs>          Per-input timeout in seconds (default: 5)
  --binary <path>    Instrumented binary for ambiguous -e shell commands
  --layout <kind>    Force layout: 'afl' or 'flat' (default: auto-detect)
  -v                 Verbose output
  -q                 Quiet mode (suppress all [+] output)
  -V                 Print version and exit
  -h, --help         Print this help and exit
```

The command outputs a **Stability Report** showing corpus size, number of runs, and the stability percentage (stable executed lines / total executed lines). If unstable lines are found, they are listed with file paths and line number ranges. If any pass failed to collect or merge its profiles, it is skipped and the report notes how many runs were actually analyzed. If inputs were excluded because they did not produce coverage in every pass, the report adds an `Inputs used` line.

Examples:

```bash
cov-analysis stability -d out/ -e "./cov @@"
cov-analysis stability -d out/ -e "./cov @@" -n 8 -s src/
cov-analysis stability -d out/ -e "./cov @@" --exclude-regex '\.h$'
cov-analysis stability -d ./corpus -e "./cov @@" -t 4
cov-analysis stability -d out/ -e "./cov @@" -T 2
```

### cov-analysis search

```
Usage: cov-analysis search FILE:LINE -d <dir> -e "<cmd>" [options]

  Report which corpus entries reach a given source line. Each input is replayed
  in isolation; an input "reaches" FILE:LINE when its line-execution count for
  that line is > 0. Matching input paths print to stdout (sorted, one per line);
  progress and the summary go to stderr.

Required:
  FILE:LINE   Source location, e.g. src/foo.c:123 (single line)
  -d <dir>    Fuzzing output directory (AFL++, libFuzzer, libafl, or honggfuzz)
  -e <cmd>    Coverage command. Use @@ as input file placeholder.
              Omit @@ to feed input via stdin instead. For a cov-analysis
              driver binary (which reads files, not stdin), @@ is appended
              automatically when omitted.

Optional:
  --crashes          Also scan crash and timeout inputs (default: corpus only)
  -t <num>           Parallel workers for the per-input scan (default: 1)
  -T <secs>          Per-input replay timeout in seconds (default: 5)
                     Applies in both union and isolated replay
  --binary <path>    Instrumented binary for ambiguous -e shell commands
  --layout <kind>    Force layout: 'afl' or 'flat' (default: auto-detect)
  -v                 Verbose output
  -q                 Quiet mode
  -V                 Print version and exit
  -h, --help         Print this help and exit
```

## License

`cov-analysis` is released under the **GNU Affero General Public License 3**.
