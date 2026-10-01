# v1.3-dev
- added --batch for better performance
- fixed AFL++ directory, it is .../hangs not .../timeouts
- more performance fixes
- fixed batch replay: a batch that crashes, exits non-zero or hits its deadline is discarded and its inputs are replayed one per process, so one bad input no longer drops the coverage of the rest of its batch, and only that input is counted as failed; the run says how many batches were replayed that way and points at `--batch 0` when most were
- fixed input file names containing `&` or `\`: under bash 5.2+ they were passed to the target mangled, and the text after `&` ran as a command
- stability: a cov-analysis driver binary now runs each input N+1 times in one process and records every run but the first, as AFL++ calibrates in persistent mode, so state a harness carries between executions is reported as instability; `--isolated` keeps the fresh-process replay, and the report's `Replay` line says which one ran. Rebuild existing driver binaries with the current `cov-analysis driver` to get this
- LibAFL output directories (`corpus/` or `queue/` next to `crashes/` or `solutions/`) are detected as their own layout (`--layout libafl`), hidden files such as LibAFL's `.metadata` and `.lafl_lock` are never replayed, and a run that selects no input says so instead of blaming the instrumentation
- fixed Ctrl-C in `stability` and `search`: they used to delete their workspace and carry on; now they stop, and every command also stops the targets still running under their replay deadline
- driver: an input that exceeds `COV_INPUT_TIMEOUT` is named and the driver exits with status 124 at once, using only async-signal-safe calls, instead of jumping back into its loop, which could deadlock when the alarm fired inside `malloc`. The rest of its batch is replayed one input per process. Rebuild existing driver binaries to get this
- driver: fixed the profile of an input stopped at its deadline. `timeout` sends TERM twice, to the target and to its process group, and with `SA_RESETHAND` the second could kill the target before its crash handler had written the profile (always with uutils `timeout`, often with GNU's). The handler now blocks every signal while it writes, so the driver's own alarm cannot cut that write short either. Rebuild existing driver binaries to get this
- on a binary that is not a cov-analysis driver, a batch's deadline is capped at 10 times the queue timeout, so a hang in it no longer holds a worker for up to batch size x queue timeout. A driver bounds each input itself, so its batches keep the full deadline and a slow but healthy batch is not killed
- `--remote`: Ctrl-C or a dropped connection now stops the replay on the remote host before its working directory is removed, and the cleanup gives up on an unreachable host after 15 seconds; `--ssh-opts` accepts shell-style quoting for values that contain spaces
- the report lock is built complete and renamed into place, and a stale or `--force`d lock is replaced only under a takeover guard, so two runs starting together can no longer both take it; `--clean` removes a half-built lock and a stale guard
- publication swaps the new report into place with `mv --exchange` where available (GNU coreutils 9.5+, current uutils coreutils), so the report directory never goes missing during a run

# v1.2
- multi-campaign: repeat `-d`/`-e` (with `--name`, `--binary`) to get a report per harness, a union report over all of them, and `attribution.txt`/`.html` showing which lines only one campaign reaches; mismatched campaign binaries are reported instead of silently under-reporting
- split replay from rendering: `--replay-only` publishes just `coverage.profdata`, `--profdata <file>` (repeatable) renders from profiles produced earlier
- remote replay: `--remote [user@]host` (`--remote-dir`, `--ssh-opts`) copies the script to the host, replays there, fetches only the profile and cleans up
- gap inventory: every `report` run writes `gaps.txt`, uncovered files and functions ranked by absolute uncovered regions (not percentage), split into actionable vs statically dead under `--reachability`
- replay correctness: inputs are always passed as absolute paths (the driver `realpath()`s them before `LLVMFuzzerInitialize`), and profiles are named per input index so PID reuse can no longer make one replay overwrite another's coverage
- replay accounting: every input's exit status is tallied and printed; unreadable inputs make the driver exit 2 and fail the run, and `--max-replay-failures` (default 99%) fails a run whose queue mostly did not replay — crashes and timeouts stay exempt
- replay progress: a `12299 queue files: 4210 done, 340/s, ~19s left` line on stderr at most every two seconds, so a wedged replay is visible immediately
- queue deadline: `--queue-timeout` bounds queue/corpus replay, derived by default from the campaign's largest `slowest_exec_ms` (x5, minimum 5s; 60s without `fuzzer_stats`, `0` disables). Enforcement is TERM-then-KILL so a killed process keeps its coverage, batch mode adds the driver's own `COV_INPUT_TIMEOUT` alarm, and inputs that hit the deadline are named in `slow_inputs.txt`
- one run per report directory: a run locks `-o` and a second is refused by pid, `--force` takes it over, `--clean` removes stale lock and staging directories, and a hung-up session no longer leaks its workspace
- `-V` prints version, content hash and path, so two installations can be told apart
- stability: passes are compared over the inputs that produced a profile in *every* pass, so an input that crosses the deadline in one pass no longer reads as instability; macro definition lines are reported separately with their expansion-site count; added `--exclude-regex`

# v1.1
- report: publish complete reports transactionally, refuse unmarked non-empty destinations, and support explicit migration of legacy reports
- replay: run all `-e` commands consistently through Bash, add `--binary` for complex commands, and enforce process-group timeouts
- build: preserve existing compiler flags and pair versioned or absolute Clang/Clang++ selections
- diff/stability/search: add `--only-changed`, base stability on executed lines, and handle crash-only searches correctly
- portability: validate required tools and support both GNU and uutils coreutils
- reachability: per-line HTML/text tinting now attributes each source line to the function whose smallest own-file code region contains it (llvm-cov's innermost-segment model) instead of painting the min..max region envelope; an inlined-macro expansion region (mapped to the macro's `#define` line) no longer stretches a function's span across the file and mistints unrelated lines, so dead functions tint grey even in dense C++ harnesses. Recomputed tally/summary numbers are unaffected (they already come from `llvm-cov report -show-functions`).
- reachability: `report` and `diff` now share one Python library (`reach_py_lib`) so both classify functions identically
- reachability: match Rust legacy-mangling disambiguators (`17h<hash>E`) and fall back to a (file, line) join for v0-mangled names
- reachability: file-qualify `static` function matches so same-named statics in different files no longer collide
- reachability: the reachable-only coverage recompute now disambiguates statics by `(file, symbol)` (the same qualified key the tally uses) and resolves any residual bare-name collision reachable-wins, so it never drops a live function from the denominators or contradicts the tally banner
- reachability: a `--reachability` directory now prefers a `reachability.json` inside it over `reached.txt`/`not_reached.txt`
- reachability: the amber "reachable but not reached" tint is now graded by the JSON report's per-function `confidence` (`reach-amber`/`reach-amber-indirect`/`reach-amber-low` for `high`/`medium`/`low`) instead of a plain `indirect_only` two-way split

# v1.0
- initial release
