#!/bin/bash
set -e

# Usage:
#   ./build.sh                — clean, install deps, compile, run demo
#   ./build.sh --test         — same as above plus `rake test`
#   ./build.sh --valgrind     — same as --test, then run script/valgrind.sh
#   ./build.sh --sanitize     — rebuild under ASAN/UBSAN, then run tests
#                               (mutually exclusive with default build)

MODE="default"
for arg in "$@"; do
  case "$arg" in
    --test)     MODE="test" ;;
    --valgrind) MODE="valgrind" ;;
    --sanitize) MODE="sanitize" ;;
    -h|--help)
      grep -E "^#( |$)" "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      echo "Run $0 --help for usage." >&2
      exit 2
      ;;
  esac
done

if [ "$MODE" = "sanitize" ]; then
  exec ./script/sanitize.sh
fi

echo "=== MultiCompress gem — build & test ==="

echo "[1/4] Cleaning..."
rm -rf tmp/ lib/multi_compress/multi_compress.{so,bundle,dylib}
rm -f ext/multi_compress/{Makefile,mkmf.log,*.o}

echo "[2/4] Installing dependencies..."
bundle install

echo "[3/4] Compiling C extension..."
bundle exec rake compile

echo "[4/4] Running demo..."
ruby -I lib demo.rb

if [ "$MODE" = "test" ] || [ "$MODE" = "valgrind" ]; then
  echo ""
  echo "[+] Running test suite..."
  bundle exec rake test
fi

if [ "$MODE" = "valgrind" ]; then
  echo ""
  echo "[+] Running valgrind pass (this is slow — 10-50x)..."
  # valgrind may be unavailable (e.g. on recent macOS). Treat "prerequisites
  # missing" (exit 2) as a non-fatal skip so the rest of the build.sh output
  # (the "Build complete!" footer) still shows up. Real valgrind-detected
  # errors exit with 1 and DO propagate.
  set +e
  ./script/valgrind.sh
  valgrind_rc=$?
  set -e
  if [ "$valgrind_rc" -eq 2 ]; then
    echo "[+] Valgrind pass skipped (see message above)."
  elif [ "$valgrind_rc" -ne 0 ]; then
    echo "[+] Valgrind reported errors (exit $valgrind_rc)." >&2
    exit "$valgrind_rc"
  fi
fi

echo ""
echo "Build complete! To install locally:"
echo "  gem build multi_compress.gemspec"
echo "  gem install ./multi_compress-$(ruby -r ./lib/multi_compress/version -e 'puts MultiCompress::VERSION').gem"
