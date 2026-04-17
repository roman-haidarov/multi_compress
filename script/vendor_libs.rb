#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage:
#   ruby script/vendor_libs.rb
#   rake compile
#   rake test
#   gem build multi_compress.gemspec

require "fileutils"
require "open-uri"
require "digest"
require "tmpdir"

VENDOR_DIR = File.expand_path("../ext/multi_compress/vendor", __dir__)

LIBS = {
  zstd: {
    version: "1.5.2", # Pin vendored zstd to 1.5.2 because dictionary training regresses on newer versions (arm64-darwin)
    url:     "https://github.com/facebook/zstd/archive/refs/tags/v%<version>s.tar.gz",
    sha256:  nil,
    strip:   "zstd-%<version>s",
    keep:    %w[lib],
  },
  lz4: {
    version: "1.10.0",
    url:     "https://github.com/lz4/lz4/archive/refs/tags/v%<version>s.tar.gz",
    sha256:  nil,
    strip:   "lz4-%<version>s",
    keep:    %w[lib],
  },
  brotli: {
    version: "1.1.0",
    url:     "https://github.com/google/brotli/archive/refs/tags/v%<version>s.tar.gz",
    sha256:  nil,
    strip:   "brotli-%<version>s",
    keep:    %w[c/common c/enc c/dec c/include],
  },
}.freeze

def download(url, dest)
  puts "  Downloading #{url}..."
  URI.open(url) { |remote| File.binwrite(dest, remote.read) }
end

def extract(tarball, dest, strip_prefix:, keep_dirs:)
  require "rubygems/package"
  require "zlib"

  puts "  Extracting..."
  FileUtils.mkdir_p(dest)

  prefix_re = /\A#{Regexp.escape(strip_prefix)}\//

  Gem::Package::TarReader.new(Zlib::GzipReader.open(tarball)) do |tar|
    tar.each do |entry|
      relative_path = entry.full_name.sub(prefix_re, "")
      next if relative_path.empty? || relative_path == entry.full_name
      next unless keep_dirs.any? { |d| relative_path.start_with?(d) }

      target = File.join(dest, relative_path)

      case
      when entry.directory?
        FileUtils.mkdir_p(target)
      when entry.file?
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, entry.read)
      end
    end
  end
end

def verify_checksum!(tarball, name, expected_sha256)
  actual = Digest::SHA256.file(tarball).hexdigest

  if expected_sha256
    abort "SHA256 mismatch for #{name}! Expected #{expected_sha256}, got #{actual}" unless actual == expected_sha256
    puts "  SHA256 verified."
  else
    puts "  SHA256: #{actual} (pin this in production!)"
  end
end

def vendor_library(name, config, tmpdir)
  version = config[:version]
  url     = format(config[:url], version: version)
  strip   = format(config[:strip], version: version)
  tarball = File.join(tmpdir, "#{name}-#{version}.tar.gz")
  dest    = File.join(VENDOR_DIR, name.to_s)

  puts "=== #{name} #{version} ==="

  download(url, tarball)
  verify_checksum!(tarball, name, config[:sha256])
  extract(tarball, dest, strip_prefix: strip, keep_dirs: config[:keep])

  puts "  -> #{dest}"
  puts
end

def write_manifest!
  manifest = LIBS.map { |name, config| "#{name}=#{config[:version]}" }.join("\n")
  File.write(File.join(VENDOR_DIR, ".vendored"), manifest)
end

puts "Vendoring C libraries into #{VENDOR_DIR}"
puts

FileUtils.rm_rf(VENDOR_DIR)
FileUtils.mkdir_p(VENDOR_DIR)

tmpdir = File.join(Dir.tmpdir, "multi_compress-vendor-#{$$}")
FileUtils.mkdir_p(tmpdir)

begin
  LIBS.each { |name, config| vendor_library(name, config, tmpdir) }

  write_manifest!

  puts "Done! Vendored sources are in ext/multi_compress/vendor/"
  puts "Now run: gem build multi_compress.gemspec"
ensure
  FileUtils.rm_rf(tmpdir)
end
