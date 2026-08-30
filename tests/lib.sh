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
  got=$(tr -cd '\0' | wc -c | awk '{print $1}')
  assert_eq "$got" "$want" "$label"
}

# mkfixture_afl_single <dir>
# Single-instance AFL++ layout: <dir>/{queue,crashes,timeouts}/id:*
mkfixture_afl_single() {
  local d="$1"
  mkdir -p "$d/queue" "$d/crashes" "$d/hangs"
  : > "$d/queue/id:000000,time:0,src:000"
  : > "$d/queue/id:000001,time:100,src:000"
  : > "$d/crashes/id:000000,sig:11,src:000"
  : > "$d/hangs/id:000000,src:000"
  : > "$d/fuzzer_stats"
}

# mkfixture_afl_parallel <dir>
# Parallel AFL++ sync_dir layout: <dir>/<worker>/{queue,crashes,timeouts}/id:*
mkfixture_afl_parallel() {
  local d="$1" w
  for w in main secondary1 secondary2; do
    mkdir -p "$d/$w/queue" "$d/$w/crashes" "$d/$w/hangs"
    : > "$d/$w/queue/id:000000,time:0,src:000"
    : > "$d/$w/queue/id:000001,time:10,src:000"
    : > "$d/$w/fuzzer_stats"
  done
  : > "$d/main/crashes/id:000000,sig:11,src:000"
  : > "$d/secondary1/hangs/id:000000,src:000"
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
mktmp() { mktemp -d "${TMPDIR:-/tmp}/afl-cov-test.XXXXXX"; }

# detect_clang — echo a usable clang binary name (clang or clang-NN), return 1
# if none is found. Used by toolchain-gated integration tests to skip cleanly.
detect_clang() {
  if command -v clang >/dev/null 2>&1; then echo clang; return 0; fi
  local v
  for v in 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11; do
    if command -v "clang-$v" >/dev/null 2>&1; then echo "clang-$v"; return 0; fi
  done
  return 1
}

rustc_llvm_major() {
  rustc -vV 2>/dev/null | awk -F: '/^LLVM version:/ { gsub(/^[ \t]+/, "", $2); split($2, v, "."); print v[1]; exit }'
}

llvm_tool_major() {
  local tool="$1" out
  out="$("$tool" --version 2>/dev/null || true)"
  case "$out" in
    *'Apple clang'*) return 1 ;;
  esac
  printf '%s\n' "$out" | grep -Eio '(clang|LLVM) version [0-9]+' \
    | grep -Eo '[0-9]+' | head -n1
}

matching_llvm_tool() {
  local base="$1" major="$2" candidate found got
  for candidate in "$base" "$base-$major"; do
    found="$(command -v "$candidate" 2>/dev/null || true)"
    test -n "$found" || continue
    got="$(llvm_tool_major "$found" || true)"
    if test "$got" = "$major"; then
      printf '%s\n' "$found"
      return 0
    fi
  done
  return 1
}

select_rust_llvm_toolchain() {
  local major clang cov prof
  major="$(rustc_llvm_major)"
  test -n "$major" || return 1
  clang="$(matching_llvm_tool clang "$major")" || return 1
  cov="$(matching_llvm_tool llvm-cov "$major")" || return 1
  prof="$(matching_llvm_tool llvm-profdata "$major")" || return 1
  printf '%s\t%s\t%s\t%s\n' "$major" "$clang" "$cov" "$prof"
}
