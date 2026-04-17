require "minitest/autorun"
require "multi_compress"
require "stringio"

class TestMultiCompress < Minitest::Test
  def setup
    @data = "Hello, World! " * 100  
    @large_data = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " * 1000  
    @empty_data = ""
    @binary_data = (0..255).to_a.pack("C*") * 10  
  end

  
  def test_algorithms_available
    expected_algos = [:zstd, :lz4, :brotli]
    assert_equal expected_algos, MultiCompress.algorithms

    expected_algos.each do |algo|
      assert MultiCompress.available?(algo), "#{algo} should be available"
      refute_nil MultiCompress.version(algo), "#{algo} version should be available"
    end
  end

  def test_compress_decompress_roundtrip
    [:zstd, :lz4, :brotli].each do |algo|
      [@data, @large_data, @binary_data].each do |test_data|
        compressed = MultiCompress.compress(test_data, algo: algo)
        decompressed = MultiCompress.decompress(compressed, algo: algo)

        assert_equal test_data, decompressed, "#{algo} roundtrip failed for #{test_data.bytesize} bytes"
        assert compressed.bytesize < test_data.bytesize, "#{algo} should compress data" unless test_data.empty?
      end
    end
  end

  def test_empty_data_handling
    [:zstd, :lz4, :brotli].each do |algo|
      compressed = MultiCompress.compress(@empty_data, algo: algo)
      decompressed = MultiCompress.decompress(compressed, algo: algo)
      assert_equal @empty_data, decompressed, "#{algo} should handle empty data"
    end
  end

  
  def test_shortcut_methods
    compressed_zstd = MultiCompress.zstd(@data)
    assert_equal @data, MultiCompress.zstd_decompress(compressed_zstd)

    compressed_zstd_level = MultiCompress.zstd(@data, level: 1)
    assert_equal @data, MultiCompress.zstd_decompress(compressed_zstd_level)

    compressed_lz4 = MultiCompress.lz4(@data)
    assert_equal @data, MultiCompress.lz4_decompress(compressed_lz4)

    compressed_lz4_level = MultiCompress.lz4(@data, level: 9)
    assert_equal @data, MultiCompress.lz4_decompress(compressed_lz4_level)

    compressed_brotli = MultiCompress.brotli(@data)
    assert_equal @data, MultiCompress.brotli_decompress(compressed_brotli)

    compressed_brotli_level = MultiCompress.brotli(@data, level: 11)
    assert_equal @data, MultiCompress.brotli_decompress(compressed_brotli_level)
  end

  
  def test_compression_levels
    [:zstd, :lz4, :brotli].each do |algo|
      compressed_default = MultiCompress.compress(@data, algo: algo)
      compressed_1 = MultiCompress.compress(@data, algo: algo, level: 1)
      compressed_max = MultiCompress.compress(@data, algo: algo, level: 
        case algo
        when :zstd then 22
        when :lz4 then 16
        when :brotli then 11
        end)

      assert_equal @data, MultiCompress.decompress(compressed_default, algo: algo)
      assert_equal @data, MultiCompress.decompress(compressed_1, algo: algo)
      assert_equal @data, MultiCompress.decompress(compressed_max, algo: algo)
    end
  end

  def test_named_levels
    [:fastest, :default, :best].each do |level|
      [:zstd, :lz4, :brotli].each do |algo|
        compressed = MultiCompress.compress(@data, algo: algo, level: level)
        decompressed = MultiCompress.decompress(compressed, algo: algo)
        assert_equal @data, decompressed, "#{algo} #{level} level failed"
      end
    end
  end

  def test_auto_detection
    compressed_zstd = MultiCompress.compress(@data, algo: :zstd)
    decompressed = MultiCompress.decompress(compressed_zstd) 
    assert_equal @data, decompressed, "ZSTD auto-detection failed"
  end

  def test_invalid_algorithm
    assert_raises(ArgumentError) { MultiCompress.compress(@data, algo: :invalid) }
    assert_raises(ArgumentError) { MultiCompress.decompress(@data, algo: :invalid) }
    assert_raises(ArgumentError) { MultiCompress.available?(:invalid) }
  end

  def test_invalid_data_decompress
    garbage = "this is not compressed data"

    [:zstd, :lz4, :brotli].each do |algo|
      assert_raises(MultiCompress::DataError) do
        MultiCompress.decompress(garbage, algo: algo)
      end
    end
  end

  def test_invalid_compression_level
    assert_raises(MultiCompress::LevelError) { MultiCompress.compress(@data, algo: :zstd, level: :invalid) }
    assert_raises { MultiCompress.compress(@data, algo: :zstd, level: 999) }
    assert_raises { MultiCompress.compress(@data, algo: :lz4, level: 999) }
    assert_raises { MultiCompress.compress(@data, algo: :brotli, level: 999) }
  end

  
  def test_deflater_basic
    [:zstd, :lz4, :brotli].each do |algo|
      deflater = MultiCompress::Deflater.new(algo: algo)
      compressed = ""
      compressed << deflater.write(@data[0, 500])
      compressed << deflater.write(@data[500..-1])
      compressed << deflater.finish
      deflater.close

      decompressed = MultiCompress.decompress(compressed, algo: algo)
      assert_equal @data, decompressed, "#{algo} Deflater failed"
      assert deflater.closed?, "#{algo} Deflater should be closed"
    end
  end

  def test_deflater_flush
    deflater = MultiCompress::Deflater.new(algo: :zstd)
    compressed = ""
    compressed << deflater.write(@data[0, 500])
    compressed << deflater.flush  
    compressed << deflater.write(@data[500..-1])
    compressed << deflater.finish
    deflater.close

    decompressed = MultiCompress.decompress(compressed, algo: :zstd)
    assert_equal @data, decompressed, "Deflater flush should work"
  end

  def test_deflater_reset
    deflater = MultiCompress::Deflater.new(algo: :zstd)
    compressed1 = ""
    compressed1 << deflater.write(@data)
    compressed1 << deflater.finish

    deflater.reset
    compressed2 = ""
    compressed2 << deflater.write(@data)
    compressed2 << deflater.finish
    deflater.close

    assert_equal @data, MultiCompress.decompress(compressed1, algo: :zstd)
    assert_equal @data, MultiCompress.decompress(compressed2, algo: :zstd)
  end

  def test_inflater_basic
    [:zstd, :lz4, :brotli].each do |algo|
      compressed = MultiCompress.compress(@data, algo: algo)
      inflater = MultiCompress::Inflater.new(algo: algo)
      decompressed = ""
      decompressed << inflater.write(compressed[0, compressed.bytesize/2])
      decompressed << inflater.write(compressed[compressed.bytesize/2..-1])
      inflater.finish
      inflater.close

      assert_equal @data, decompressed, "#{algo} Inflater failed"
      assert inflater.closed?, "#{algo} Inflater should be closed"
    end
  end

  def test_reader_open_accepts_limit_kwargs
    compressed = MultiCompress.compress(@data, algo: :zstd)
    io = StringIO.new(compressed)

    result = MultiCompress::Reader.open(io, algo: :zstd, max_output_size: 1 * 1024 * 1024, max_ratio: 1000) do |reader|
      reader.read
    end

    assert_equal @data, result
  end

  def test_streaming_closed_operations
    deflater = MultiCompress::Deflater.new(algo: :zstd)
    deflater.close

    assert_raises(MultiCompress::StreamError) { deflater.write(@data) }
    assert_raises(MultiCompress::StreamError) { deflater.flush }
    assert_raises(MultiCompress::StreamError) { deflater.finish }

    inflater = MultiCompress::Inflater.new(algo: :zstd)
    inflater.close

    assert_raises(MultiCompress::StreamError) { inflater.write(@data) }
    assert_raises(MultiCompress::StreamError) { inflater.finish }
  end

  def test_crc32
    crc1 = MultiCompress.crc32(@data)
    crc2 = MultiCompress.crc32(@data)
    assert_equal crc1, crc2, "CRC32 should be deterministic"

    crc_part1 = MultiCompress.crc32(@data[0, 10])
    crc_full = MultiCompress.crc32(@data[10..-1], crc_part1)
    assert_equal MultiCompress.crc32(@data), crc_full, "Incremental CRC32 should work"
  end

  def test_adler32
    adler1 = MultiCompress.adler32(@data)
    adler2 = MultiCompress.adler32(@data)
    assert_equal adler1, adler2, "Adler32 should be deterministic"

    adler_part1 = MultiCompress.adler32(@data[0, 10])
    adler_full = MultiCompress.adler32(@data[10..-1], adler_part1)
    assert_equal MultiCompress.adler32(@data), adler_full, "Incremental Adler32 should work"
  end

  
  def test_large_data_compression
    [:zstd, :lz4, :brotli].each do |algo|
      compressed = MultiCompress.compress(@large_data, algo: algo)
      decompressed = MultiCompress.decompress(compressed, algo: algo)
      assert_equal @large_data, decompressed, "#{algo} should handle large data"
    end
  end

  def test_repeated_pattern_compression
    repeated_data = "A" * 10000

    [:zstd, :lz4, :brotli].each do |algo|
      compressed = MultiCompress.compress(repeated_data, algo: algo)
      decompressed = MultiCompress.decompress(compressed, algo: algo)
      assert_equal repeated_data, decompressed
      assert compressed.bytesize < repeated_data.bytesize / 10, "#{algo} should compress repeated patterns well"
    end
  end

  def test_random_data_compression
    random_data = Random.new(42).bytes(10000)

    [:zstd, :lz4, :brotli].each do |algo|
      compressed = MultiCompress.compress(random_data, algo: algo)
      decompressed = MultiCompress.decompress(compressed, algo: algo)
      assert_equal random_data, decompressed, "#{algo} should handle random data"
    end
  end

  def test_dictionary_unsupported_lz4
    sample_dict = "common patterns here"
    assert_raises(MultiCompress::UnsupportedError) do
      MultiCompress::Dictionary.new(sample_dict, algo: :lz4)
    end
  end

  def test_dictionary_basic
    [:zstd, :brotli].each do |algo|
      dict_data = "Hello World compression dictionary"
      dict = MultiCompress::Dictionary.new(dict_data, algo: algo)

      assert_equal algo, dict.algo
      assert_equal dict_data.bytesize, dict.size

      compressed = MultiCompress.compress(@data, algo: algo, dictionary: dict)
      decompressed = MultiCompress.decompress(compressed, algo: algo, dictionary: dict)
      assert_equal @data, decompressed, "#{algo} dictionary compression failed"
    end
  end
end
