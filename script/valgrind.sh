#!/usr/bin/env bash
set -euo pipefail

# Local helper only. Intentionally not wired into CI — valgrind is too slow
# for per-commit runs (10-50x slowdown). Run this before releases or when
# investigating suspected memory bugs in the native extension.
#
# Usage:
#   script/valgrind.sh
#   script/valgrind.sh test/test_docs_parity.rb test/test_limits.rb
#
# Default targets cover lifetime-sensitive code paths:
#   - fiber scheduler integration
#   - concurrent dictionary/stream usage
#   - limit enforcement
#   - malformed input handling
#
# Exit codes:
#   0 — clean, no definite leaks or invalid memory access
#   1 — valgrind reported an error
#   2 — valgrind not installed or prerequisites missing

if ! command -v valgrind >/dev/null 2>&1; then
  echo "valgrind is not installed" >&2
  echo "  Ubuntu/Debian: sudo apt-get install -y valgrind" >&2
  echo "  macOS: valgrind support on recent macOS is limited — prefer ASAN instead" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "[valgrind] Ensuring extension is compiled..."
bundle exec rake compile >/dev/null

if [ "$#" -eq 0 ]; then
  TEST_FILES=(
    test/test_docs_parity.rb
    test/test_limits.rb
    test/test_security_and_detection.rb
    test/test_fiber_scheduler.rb
    test/test_concurrent_operations.rb
  )
else
  TEST_FILES=("$@")
fi

# Filter out missing test files gracefully (e.g. if a test file is excluded by policy)
EXISTING_TESTS=()
for f in "${TEST_FILES[@]}"; do
  if [ -f "$f" ]; then
    EXISTING_TESTS+=("$f")
  else
    echo "[valgrind] Skipping missing test file: $f" >&2
  fi
done

if [ "${#EXISTING_TESTS[@]}" -eq 0 ]; then
  echo "[valgrind] No test files to run" >&2
  exit 2
fi

echo "[valgrind] Running against: ${EXISTING_TESTS[*]}"

SUPP_FILE="$REPO_ROOT/script/valgrind-ruby.supp"
SUPP_ARG=()
if [ -f "$SUPP_FILE" ]; then
  SUPP_ARG=(--suppressions="$SUPP_FILE")
  echo "[valgrind] Using suppressions file: $SUPP_FILE"
else
  echo "[valgrind] No suppressions file found — Ruby VM noise may appear in output"
fi

# --show-leak-kinds=definite: only report true leaks, not "reachable" VM state
# --errors-for-leak-kinds=definite: let definite leaks fail the run
# --error-exitcode=1: fail if any error is reported at all
# --track-origins=yes: helpful for uninitialized-value diagnosis
# --num-callers=30: deeper stack traces are worth the cost
valgrind \
  --leak-check=full \
  --show-leak-kinds=definite \
  --errors-for-leak-kinds=definite \
  --error-exitcode=1 \
  --track-origins=yes \
  --num-callers=30 \
  "${SUPP_ARG[@]}" \
  ruby -Ilib -Itest -e 'ARGV.each { |file| require File.expand_path(file) }' \
  "${EXISTING_TESTS[@]}"

echo "[valgrind] Clean run — no definite leaks or invalid access detected."
