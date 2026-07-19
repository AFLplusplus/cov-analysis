# v1.2
- ...

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
