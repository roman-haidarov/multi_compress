#!/usr/bin/env bash
set -euo pipefail

# Local helper for running the test suite under AddressSanitizer +
# UndefinedBehaviorSanitizer. Mirrors the CI sanitizers job so that
# developers can reproduce CI failures locally.
#
# Usage:
#   script/sanitize.sh
#   script/sanitize.sh test/test_limits.rb
#
# Prerequisites:
#   - Linux (macOS ASAN support via clang works but needs extra setup;
#     CI runs this on Linux only)
#   - gcc or clang with sanitizer runtime available
#   - Ruby built without conflicting instrumentation
#
# Exit codes:
#   0 — clean run
#   1 — sanitizer reported an error or a test failed
#   2 — prerequisites missing

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ "$(uname -s)" != "Linux" ]; then
  echo "script/sanitize.sh is intended for Linux. On macOS prefer Xcode's" >&2
  echo "built-in sanitizer support or run the ASAN job in CI." >&2
  exit 2
fi

# Locate the libasan runtime. Required for LD_PRELOAD so Ruby's own
# allocator does not short-circuit ASAN.
LIBASAN=""
for candidate in \
  /usr/lib/x86_64-linux-gnu/libasan.so.8 \
  /usr/lib/x86_64-linux-gnu/libasan.so.6 \
  /usr/lib/x86_64-linux-gnu/libasan.so.5 \
  /usr/lib64/libasan.so.8 \
  /usr/lib64/libasan.so.6
do
  if [ -f "$candidate" ]; then
    LIBASAN="$candidate"
    break
  fi
done

if [ -z "$LIBASAN" ]; then
  echo "Could not locate libasan.so. Install it via:" >&2
  echo "  Ubuntu/Debian: sudo apt-get install -y libasan8" >&2
  exit 2
fi

echo "[sanitize] Using libasan: $LIBASAN"

echo "[sanitize] Cleaning previous build artifacts..."
rm -f ext/multi_compress/*.o \
      ext/multi_compress/Makefile \
      lib/multi_compress/multi_compress.so

echo "[sanitize] Compiling extension with -fsanitize=address,undefined..."
CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all -g -O1" \
LDFLAGS="-fsanitize=address,undefined" \
bundle exec rake compile

# ASAN options:
#   detect_leaks=0    — suppress leak reporter (Ruby is expected to leak at exit)
#   halt_on_error=1   — stop at first error, easier to triage
#   abort_on_error=1  — get a core-dump style failure for debuggers
# UBSAN options:
#   halt_on_error=1
#   print_stacktrace=1
export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1:abort_on_error=1:symbolize=1:protect_shadow_gap=0:verify_asan_link_order=0"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1:symbolize=1"
export LD_PRELOAD="$LIBASAN"

if [ "$#" -eq 0 ]; then
  echo "[sanitize] Running full test suite..."
  bundle exec rake test
else
  echo "[sanitize] Running: $*"
  ruby -Ilib -Itest -e 'ARGV.each { |f| require File.expand_path(f) }' "$@"
fi

echo "[sanitize] Clean run — no sanitizer errors."
