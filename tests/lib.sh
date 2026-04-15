# tests/lib.sh — test helpers used by every tests/test_*.sh

# die "message" → print to stderr and exit 1
die() { echo "[FAIL] $*" >&2; exit 1; }

# assert_eq <actual> <expected> <label>
assert_eq() {
  if [ "$1" != "$2" ]; then
    die "$3: expected '$2', got '$1'"
  fi
}

# assert_count <expected> <label> < null-delimited-stream
assert_count() {
  local want="$1" label="$2"
  local got
  got=$(tr -cd '\0' | wc -c)
  assert_eq "$got" "$want" "$label"
}

# mkfixture_afl_single <dir>
# Single-instance AFL++ layout: <dir>/{queue,crashes,timeouts}/id:*
mkfixture_afl_single() {
  local d="$1"
  mkdir -p "$d/queue" "$d/crashes" "$d/timeouts"
  : > "$d/queue/id:000000,time:0,src:000"
  : > "$d/queue/id:000001,time:100,src:000"
  : > "$d/crashes/id:000000,sig:11,src:000"
  : > "$d/timeouts/id:000000,src:000"
  : > "$d/fuzzer_stats"
}

# mkfixture_afl_parallel <dir>
# Parallel AFL++ sync_dir layout: <dir>/<worker>/{queue,crashes,timeouts}/id:*
mkfixture_afl_parallel() {
  local d="$1" w
  for w in main secondary1 secondary2; do
    mkdir -p "$d/$w/queue" "$d/$w/crashes" "$d/$w/timeouts"
    : > "$d/$w/queue/id:000000,time:0,src:000"
    : > "$d/$w/queue/id:000001,time:10,src:000"
    : > "$d/$w/fuzzer_stats"
  done
  : > "$d/main/crashes/id:000000,sig:11,src:000"
  : > "$d/secondary1/timeouts/id:000000,src:000"
}

# mkfixture_libfuzzer <dir>
# libFuzzer corpus + artifacts in a flat dir
mkfixture_libfuzzer() {
  local d="$1"
  mkdir -p "$d"
  : > "$d/0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"
  : > "$d/feedc0ffee1122334455667788990011aabbccdd"
  : > "$d/crash-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  : > "$d/leak-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  : > "$d/oom-cccccccccccccccccccccccccccccccccccccccc"
  : > "$d/timeout-dddddddddddddddddddddddddddddddddddddddd"
  : > "$d/slow-unit-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
}

# mkfixture_honggfuzz <dir>
# honggfuzz workspace: corpus files + SIG*.fuzz crashes + report
mkfixture_honggfuzz() {
  local d="$1"
  mkdir -p "$d"
  : > "$d/input.000001.honggfuzz.cov"
  : > "$d/input.000002.honggfuzz.cov"
  : > "$d/SIGSEGV.PC.7f0000000000.STACK.abcdef123.CODE.1.ADDR.0.INSTR.mov_rax_rbx.fuzz"
  : > "$d/SIGABRT.PC.7f0000000001.STACK.112233445.CODE.1.ADDR.0.INSTR.call.fuzz"
  : > "$d/HONGGFUZZ.REPORT.TXT"
}

# mktmp — returns a tempdir path; auto-cleanup on EXIT via caller's trap
mktmp() { mktemp -d "/tmp/afl-cov-test.XXXXXX"; }
