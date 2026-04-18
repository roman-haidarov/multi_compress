require "minitest/autorun"
require "multi_compress"
require "tempfile"

class TestLimits < Minitest::Test
  CHUNK_A = "A" * 70_000
  CHUNK_B = "B" * 70_000

  def one_shot_limit_payload
    @one_shot_limit_payload ||= "limit-test-" * 4_000
  end

  def ratio_payload
    @ratio_payload ||= Array.new(20_000) do |i|
      %Q({"path":"/api/v1/items/#{i}","status":"ok","env":"prod","region":"us-east-1","tenant":"tenant-#{i % 100}","trace":"#{i.to_s(36).rjust(10, "0")}","tags":["alpha","beta","gamma"],"message":"structured payload #{i % 64}"}\n)
    end.join
  end

  def fake_lz4_blob(*blocks)
    body = blocks.map do |orig_size, comp_size|
      [orig_size, comp_size].pack("L<L<") + ("\x00" * comp_size)
    end.join
    body + [0].pack("L<")
  end

  def streaming_parts_for(algo)
    deflater = MultiCompress::Deflater.new(algo: algo)
    parts = []
    [CHUNK_A, CHUNK_B].each do |chunk|
      piece = deflater.write(chunk)
      parts << piece unless piece.nil? || piece.empty?
    end
    final_piece = deflater.finish
    parts << final_piece unless final_piece.nil? || final_piece.empty?
    deflater.close
    parts
  end

  def test_one_shot_max_output_size_rejects_oversized_output
    [:zstd, :brotli, :lz4].each do |algo|
      compressed = MultiCompress.compress(one_shot_limit_payload, algo: algo)

      error = assert_raises(MultiCompress::DataError) do
        MultiCompress.decompress(compressed, algo: algo, max_output_size: 1024, max_ratio: nil)
      end

      assert_match(/exceeds limit/i, error.message)
    end
  end

  def test_streaming_max_output_size_rejects_cumulative_output
    [:zstd, :brotli, :lz4].each do |algo|
      inflater = MultiCompress::Inflater.new(algo: algo, max_output_size: 100_000, max_ratio: nil)
      error = assert_raises(MultiCompress::DataError) do
        streaming_parts_for(algo).each do |part|
          inflater.write(part)
        end
      end

      assert_match(/exceeds limit/i, error.message)
    ensure
      inflater&.close
    end
  end

  def test_max_ratio_rejects_high_ratio_payloads
    [:zstd, :brotli, :lz4].each do |algo|
      compressed = MultiCompress.compress(ratio_payload, algo: algo)
      assert_operator compressed.bytesize, :>=, 1024, "#{algo} compressed payload must be large enough to trigger ratio guard"

      error = assert_raises(MultiCompress::DataError) do
        MultiCompress.decompress(compressed, algo: algo, max_output_size: ratio_payload.bytesize * 2, max_ratio: 5)
      end

      assert_match(/ratio exceeds limit/i, error.message)
    end
  end

  def test_max_ratio_nil_disables_guard
    [:zstd, :brotli, :lz4].each do |algo|
      compressed = MultiCompress.compress(ratio_payload, algo: algo)
      decompressed = MultiCompress.decompress(compressed, algo: algo, max_output_size: ratio_payload.bytesize * 2, max_ratio: nil)
      assert_equal ratio_payload, decompressed
    end
  end

  def test_max_output_size_nil_uses_default_512mb_cap
    oversized = fake_lz4_blob(
      [200 * 1024 * 1024, 1],
      [200 * 1024 * 1024, 1],
      [113 * 1024 * 1024, 1]
    )

    error = assert_raises(MultiCompress::DataError) do
      MultiCompress.decompress(oversized, algo: :lz4, max_output_size: nil, max_ratio: nil)
    end

    assert_match(/exceeds limit/i, error.message)
  end


  def test_streaming_ratio_guard_uses_consumed_input_for_mid_chunk_trigger
    compressible = ("A" * (512 * 1024)).b
    noisy = Random.new(7).bytes(900 * 1024)

    deflater = MultiCompress::Deflater.new(algo: :lz4)
    stream = +""
    stream << deflater.write(compressible)
    stream << deflater.write(noisy)
    stream << deflater.finish
    deflater.close

    inflater = MultiCompress::Inflater.new(algo: :lz4, max_output_size: 2 * 1024 * 1024, max_ratio: 50)

    error = assert_raises(MultiCompress::DataError) do
      inflater.write(stream)
    end

    assert_match(/ratio exceeds limit/i, error.message)
  ensure
    inflater&.close
  end

  def test_dict_load_rejects_files_larger_than_32mb
    Tempfile.create("multi_compress_dict") do |file|
      file.binmode
      file.truncate(33 * 1024 * 1024)
      file.flush

      error = assert_raises(MultiCompress::DataError) do
        MultiCompress::Dictionary.load(file.path, algo: :zstd)
      end

      assert_match(/dictionary file too large/i, error.message)
    end
  end
end
