require "minitest/autorun"
require "multi_compress"

class TestSecurityAndDetection < Minitest::Test
  def setup
    @data = "Hello, World! " * 100  
  end

  def test_detect_algo_zstd_magic_bytes
    compressed_zstd = MultiCompress.compress(@data, algo: :zstd)
    decompressed = MultiCompress.decompress(compressed_zstd) 
    assert_equal @data, decompressed, "ZSTD auto-detection should work with magic bytes"
  end

  def test_detect_algo_lz4_block_header
    compressed_lz4 = MultiCompress.compress(@data, algo: :lz4)
    decompressed = MultiCompress.decompress(compressed_lz4) 
    assert_equal @data, decompressed, "LZ4 auto-detection should work with internal format validation"
  end

  def test_detect_algo_brotli_no_fallback
    compressed_brotli = MultiCompress.compress(@data, algo: :brotli)

    assert_raises(MultiCompress::DataError) do
      MultiCompress.decompress(compressed_brotli) 
    end

    decompressed = MultiCompress.decompress(compressed_brotli, algo: :brotli)
    assert_equal @data, decompressed, "Brotli should work with explicit algo"
  end

  def test_detect_algo_unknown_data_error
    garbage_data = "\x00\x01\x02\x03random garbage data that's not compressed"
    error = assert_raises(MultiCompress::DataError) do
      MultiCompress.decompress(garbage_data) 
    end

    assert_match(/not.*valid.*compressed.*data|unknown.*format|cannot.*detect/i, error.message)
  end

  def test_detect_algo_short_data
    short_data = "\x00\x01"

    assert_raises(MultiCompress::DataError) do
      MultiCompress.decompress(short_data) 
    end
  end

  
  def test_decompression_size_limit_protection
    large_data = "A" * (50 * 1024 * 1024)  
    
    [:zstd, :brotli].each do |algo|
      compressed = MultiCompress.compress(large_data, algo: algo)
      decompressed = MultiCompress.decompress(compressed, algo: algo)
      assert_equal large_data, decompressed, "#{algo} should handle 50MB data"
    end
  end

  def test_max_decompress_size_documented
    large_data = "B" * (50 * 1024 * 1024)  
    [:zstd, :brotli].each do |algo|
      compressed = MultiCompress.compress(large_data, algo: algo)
      decompressed = MultiCompress.decompress(compressed, algo: algo)
      assert_equal large_data, decompressed, "#{algo} should handle 50MB data under the limit"
    end

    [:zstd, :brotli].each do |algo|
      deflater = MultiCompress::Deflater.new(algo: algo)
      chunk_data = "C" * (10 * 1024 * 1024)  
      compressed_parts = []

      5.times do
        compressed_parts << deflater.write(chunk_data)
      end
      compressed_parts << deflater.finish
      deflater.close

      compressed = compressed_parts.join
      decompressed = MultiCompress.decompress(compressed, algo: algo)
      expected_data = chunk_data * 5
      assert_equal expected_data, decompressed, "#{algo} streaming should handle 50MB data"
    end
  end

  
  def test_lz4_internal_format_warning
    compressed_lz4 = MultiCompress.compress(@data, algo: :lz4)
    assert compressed_lz4.size >= 12, "LZ4 internal format should have at least 12 bytes (headers + end marker)"

    orig_size = compressed_lz4.unpack("L<")[0]  
    comp_size = compressed_lz4[4, 4].unpack("L<")[0]

    assert_equal @data.size, orig_size, "First 4 bytes should contain original size"
    assert comp_size > 0, "MultiCompressed size should be positive"
    assert comp_size < @data.size, "MultiCompressed size should be less than original for this data"

    end_marker = compressed_lz4[-4, 4].unpack("L<")[0]
    assert_equal 0, end_marker, "Should end with 4 zero bytes as end marker"

    lz4_frame_magic = [0x04, 0x22, 0x4D, 0x18].pack("C*")
    refute compressed_lz4.start_with?(lz4_frame_magic), "Internal LZ4 format should not use standard LZ4 frame format"
  end

  def test_lz4_format_incompatibility_with_cli
    test_string = "This is a test string for LZ4 internal format verification"
    compressed = MultiCompress.compress(test_string, algo: :lz4)
    orig_size = compressed.unpack("L<")[0]
    comp_size = compressed[4, 4].unpack("L<")[0]
    lz4_data = compressed[8, comp_size]
    end_marker = compressed[8 + comp_size, 4].unpack("L<")[0]

    assert_equal test_string.size, orig_size
    assert_equal lz4_data.size, comp_size
    assert_equal 0, end_marker
  end

  
  def test_malformed_magic_bytes
    malformed_data = [
      "\x28\xB5\x2F",           
      "\x04\x22\x4D",          
      "\x28\xB5\x2F\xFE",      
      "\x05\x22\x4D\x18",      
    ]

    malformed_data.each do |bad_data|
      assert_raises(MultiCompress::DataError) do
        MultiCompress.decompress(bad_data)
      end
    end
  end

  def test_partial_valid_magic_with_invalid_data
    zstd_magic = "\x28\xB5\x2F\xFD"
    lz4_magic = "\x04\x22\x4D\x18"

    [zstd_magic + "corrupted", lz4_magic + "corrupted"].each do |corrupted_data|
      assert_raises(MultiCompress::DataError) do
        MultiCompress.decompress(corrupted_data)
      end
    end
  end
end
