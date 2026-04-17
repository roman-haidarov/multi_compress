require "minitest/autorun"
require "multi_compress"
require "rubygems"

class TestDocsParity < Minitest::Test
  def test_supported_named_levels_are_stable_runtime_contract
    sample = "docs parity sample " * 32

    [:fastest, :default, :best].each do |level|
      [:zstd, :lz4, :brotli].each do |algo|
        compressed = MultiCompress.compress(sample, algo: algo, level: level)
        assert_equal sample, MultiCompress.decompress(compressed, algo: algo)
      end
    end

    assert_raises(MultiCompress::LevelError) do
      MultiCompress.compress(sample, algo: :zstd, level: :balanced)
    end
  end

  def test_zstd_training_is_supported
    samples = Array.new(256) do |i|
      body = (
        "event=api_request status=200 method=GET path=/v1/items/#{i % 32} " \
        "region=us-east-1 env=prod tenant=#{i % 8} " \
        "payload=#{'x' * 96} tags=#{'alpha,beta,gamma,' * 4}"
      )
      body * 2
    end

    dict = MultiCompress::Zstd.train_dictionary(samples, size: 1024)

    assert_instance_of MultiCompress::Dictionary, dict
    assert_equal :zstd, dict.algo
    assert_operator dict.size, :>, 0
  end

  def test_brotli_training_is_unsupported
    error = assert_raises(MultiCompress::UnsupportedError) do
      MultiCompress::Brotli.train_dictionary(["hello world" * 16], size: 1024)
    end

    assert_match(/not supported/i, error.message)
  end

  def test_gemspec_required_ruby_version_is_at_least_3_1
    spec = Gem::Specification.load(File.expand_path("../multi_compress.gemspec", __dir__))

    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.1.0"))
    refute spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.0.9"))
  end
end
