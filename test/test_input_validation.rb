# frozen_string_literal: true

require_relative "test_helper"

class TestInputValidation < Minitest::Test
  def test_compress_rejects_non_symbol_algo_string
    error = assert_raises(TypeError) do
      MultiCompress.compress("x", algo: "zstd")
    end

    assert_equal "algo must be a Symbol (:zstd, :lz4, :brotli)", error.message
  end

  def test_compress_rejects_non_symbol_algo_integer
    error = assert_raises(TypeError) do
      MultiCompress.compress("x", algo: 1)
    end

    assert_equal "algo must be a Symbol (:zstd, :lz4, :brotli)", error.message
  end

  def test_compress_rejects_string_level
    assert_raises(TypeError) do
      MultiCompress.compress("x", algo: :zstd, level: "9")
    end
  end

  def test_compress_rejects_non_dictionary_object
    error = assert_raises(TypeError) do
      MultiCompress.compress("x", algo: :zstd, dictionary: "raw")
    end

    assert_equal "dictionary must be a MultiCompress::Dictionary", error.message
  end

  def test_dictionary_load_rejects_null_byte_in_path
    error = assert_raises(ArgumentError) do
      MultiCompress::Dictionary.load("a\0b", algo: :zstd)
    end

    assert_match(/null byte/i, error.message)
  end

  def test_compress_rejects_algorithm_keyword
    error = assert_raises(ArgumentError) do
      MultiCompress.compress("x", algorithm: :zstd)
    end

    assert_equal "unknown keyword: :algorithm (use :algo)", error.message
  end

  def test_decompress_rejects_algorithm_keyword
    compressed = MultiCompress.compress("hello", algo: :zstd)

    error = assert_raises(ArgumentError) do
      MultiCompress.decompress(compressed, algorithm: :zstd)
    end

    assert_equal "unknown keyword: :algorithm (use :algo)", error.message
  end
end
