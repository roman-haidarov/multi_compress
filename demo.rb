#!/usr/bin/env ruby
# frozen_string_literal: true

require "multi_compress"
require "benchmark"

ALGORITHMS    = %i[zstd lz4 brotli].freeze
ITERATIONS    = 1_000
SAMPLE_DATA   = ("Hello, World! " * 1000).freeze

def print_header
  puts "MultiCompress gem v#{MultiCompress::VERSION}"
  puts "=" * 50

  puts "\nLibrary versions:"
  MultiCompress.algorithms.each do |algo|
    puts "  #{algo}: #{MultiCompress.version(algo)}"
  end
end

def demo_oneshot(data)
  puts "\n--- One-shot API ---"
  puts "Original size: #{data.bytesize} bytes"

  ALGORITHMS.each do |algo|
    compressed   = MultiCompress.compress(data, algo: algo)
    decompressed = MultiCompress.decompress(compressed, algo: algo)
    ratio        = (compressed.bytesize.to_f / data.bytesize * 100).round(1)

    puts "  #{algo}: #{compressed.bytesize} bytes (#{ratio}%) — " \
         "roundtrip OK: #{decompressed == data}"
  end
end

def demo_shortcuts(data)
  puts "\n--- Shortcut methods ---"

  [
    ["MultiCompress.zstd(level:5)",  -> { MultiCompress.zstd(data, level: 5) },  -> (c) { MultiCompress.zstd_decompress(c) }],
    ["MultiCompress.lz4",           -> { MultiCompress.lz4(data) },              -> (c) { MultiCompress.lz4_decompress(c) }],
    ["MultiCompress.brotli(level:11)", -> { MultiCompress.brotli(data, level: 11) }, -> (c) { MultiCompress.brotli_decompress(c) }],
  ].each do |label, compressor, decompressor|
    compressed   = compressor.call
    decompressed = decompressor.call(compressed)

    puts "  #{label}: #{compressed.bytesize} bytes — roundtrip OK: #{decompressed == data}"
  end
end

def demo_named_levels(data)
  puts "\n--- Named levels (zstd) ---"

  %i[fastest default best].each do |level|
    compressed = MultiCompress.compress(data, algo: :zstd, level: level)
    puts "  #{level}: #{compressed.bytesize} bytes"
  end
end

def demo_autodetect(data)
  puts "\n--- Auto-detect decompression ---"

  compressed   = MultiCompress.compress(data, algo: :zstd)
  decompressed = MultiCompress.decompress(compressed)

  puts "  zstd → auto-detect OK: #{decompressed == data}"
  puts "  lz4/brotli → auto-detect not reliable, use explicit algo: parameter"
end

def demo_benchmark(data)
  puts "\n--- Benchmark (#{data.bytesize} bytes, #{ITERATIONS} iterations) ---"

  Benchmark.bm(20) do |x|
    ALGORITHMS.each do |algo|
      compressed = MultiCompress.compress(data, algo: algo)

      x.report("#{algo} compress") do
        ITERATIONS.times { MultiCompress.compress(data, algo: algo) }
      end

      x.report("#{algo} decompress") do
        ITERATIONS.times { MultiCompress.decompress(compressed, algo: algo) }
      end
    end
  end
end

print_header
demo_oneshot(SAMPLE_DATA)
demo_shortcuts(SAMPLE_DATA)
demo_named_levels(SAMPLE_DATA)
demo_autodetect(SAMPLE_DATA)
demo_benchmark(SAMPLE_DATA)

puts "\nDone!"
