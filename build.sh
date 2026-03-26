#!/bin/bash
set -e

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

echo ""
echo "Build complete! To install locally:"
echo "  gem build multi_compress.gemspec"
echo "  gem install ./multi_compress-$(ruby -r ./lib/multi_compress/version -e 'puts MultiCompress::VERSION').gem"
