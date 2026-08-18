# v1.3-dev
- added --batch for better performance
- more performance fixes

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
