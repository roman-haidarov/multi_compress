require "minitest/autorun"
require "multi_compress"
require "stringio"

class TestConfiguration < Minitest::Test
  def setup
    @saved_max_output_size = MultiCompress.config.max_output_size
    @saved_streaming_max_output_size = MultiCompress.config.streaming_max_output_size
  end

  def teardown
    MultiCompress.configure do |config|
      config.max_output_size = @saved_max_output_size
      config.streaming_max_output_size = @saved_streaming_max_output_size
    end
  end

  def ratio_payload
    @ratio_payload ||= Array.new(20_000) do |i|
      {
        id: i,
        category: "metrics",
        status: "ok",
        tags: ["repeat", "repeat", "repeat", "repeat"],
        payload: "A" * 180,
      }
    end.to_s
  end

  def test_configure_sets_one_shot_default_and_call_override_wins
    payload = ("one-shot-config-" * 8_000)
    compressed = MultiCompress.compress(payload, algo: :zstd)

    MultiCompress.configure do |config|
      config.max_output_size = 1024
    end

    assert_raises(MultiCompress::DataError) do
      MultiCompress.decompress(compressed, algo: :zstd)
    end

    restored = MultiCompress.decompress(compressed, algo: :zstd, max_output_size: payload.bytesize)
    assert_equal payload, restored
  end

  def test_streaming_uses_separate_default_limit
    payload = ("streaming-config-" * 10_000)
    compressed = MultiCompress.compress(payload, algo: :zstd)

    MultiCompress.configure do |config|
      config.max_output_size = payload.bytesize * 2
      config.streaming_max_output_size = 1024
    end

    assert_equal payload, MultiCompress.decompress(compressed, algo: :zstd)

    error = assert_raises(MultiCompress::DataError) do
      MultiCompress::Reader.open(StringIO.new(compressed), algo: :zstd) do |reader|
        reader.read
      end
    end

    assert_match(/exceeds limit/i, error.message)
  end

  def test_default_ratio_guard_remains_active_for_one_shot
    compressed = MultiCompress.compress(ratio_payload, algo: :zstd)
    assert_operator compressed.bytesize, :>=, 1024

    assert_raises(MultiCompress::DataError) do
      MultiCompress.decompress(compressed, algo: :zstd, max_ratio: 5)
    end
  end

  def test_default_ratio_guard_remains_active_for_streaming
    compressed = MultiCompress.compress(ratio_payload, algo: :zstd)
    assert_operator compressed.bytesize, :>=, 1024

    assert_raises(MultiCompress::DataError) do
      MultiCompress::Reader.open(StringIO.new(compressed), algo: :zstd, max_ratio: 5) do |reader|
        reader.read
      end
    end
  end

  def test_config_validation_rejects_invalid_values
    assert_raises(TypeError) do
      MultiCompress.configure { |config| config.max_output_size = "1024" }
    end

    assert_raises(ArgumentError) do
      MultiCompress.configure { |config| config.streaming_max_output_size = 0 }
    end
  end
end
