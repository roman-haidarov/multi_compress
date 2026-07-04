# frozen_string_literal: true
# encoding: utf-8

require "minitest/autorun"
require "multi_compress"
require "multi_compress/codec"
require "json"

class TestCodec < Minitest::Test
  def setup
    @saved = MultiCompress.config.max_output_size
  end

  def teardown
    MultiCompress.config.max_output_size = @saved
  end

  def codec(**opts)
    MultiCompress::Codec.new(**{ algo: :zstd, level: 6 }.merge(opts))
  end

  def test_roundtrip_exact_string
    s = "x" * 500
    assert_equal s, codec.load(codec.dump(s))
  end

  def test_always_compresses_single_format
    blob = codec.dump("hi")
    assert blob.b.start_with?(MultiCompress::Codec::MAGIC), "expected magic envelope"
    assert_equal "hi", codec.load(blob)
  end

  def test_preserves_utf8_encoding_and_equality
    s = "Привет, мир"
    back = codec.load(codec.dump(s))
    assert_equal Encoding::UTF_8, back.encoding
    assert_equal s, back
  end

  def test_binary_encoding_option
    s = "\x00\x01\xFF".b
    c = codec(encoding: Encoding::BINARY)
    assert_equal s, c.load(c.dump(s))
  end

  def test_corrupt_envelope_raises_not_passthrough
    blob = codec.dump("z" * 300).dup
    blob.setbyte(blob.bytesize - 1, blob.getbyte(blob.bytesize - 1) ^ 0xFF)
    assert_raises(MultiCompress::DataError) { codec.load(blob) }
  end

  def test_non_string_without_serializer_raises
    assert_raises(TypeError) { codec.dump({ a: 1 }) }
  end

  def test_local_max_output_size_is_frozen_against_global
    MultiCompress.config.max_output_size = 512 * 1024 * 1024
    c = codec(max_output_size: 1024)
    blob = c.dump("A" * 100_000)
    assert_raises(MultiCompress::DataError) { c.load(blob) }
  end

  def test_legacy_default_rejects
    assert_raises(MultiCompress::DataError) { codec.load("\x01legacy".b) }
  end

  def test_legacy_plain_keeps_all_bytes
    c = codec(legacy: :plain)
    ["\x00abc", "\x01abc", "\x02abc", "\x03abc"].each do |v|
      assert_equal v.b, c.load(v.b).b, "first byte must survive for #{v.inspect}"
    end
  end

  def test_legacy_compressed_reads_pre_existing_raw_blob
    raw = MultiCompress.compress("y" * 400, algo: :zstd)
    c = codec(legacy: { compressed: :zstd })
    assert_equal "y" * 400, c.load(raw)
  end

  def test_base64_roundtrip_is_ascii_only
    c = codec(encode: :base64)
    s = "Привет" * 20
    blob = c.dump(s)
    assert blob.ascii_only?
    assert blob.start_with?("mc1:")
    assert_equal s, c.load(blob)
  end

  def test_base64_does_not_decode_plain_legacy_string
    c = codec(encode: :base64, legacy: :plain)
    assert_equal "test", c.load("test")
  end

  def test_json_serializer_preserves_types
    c = codec(serializer: JSON)
    obj = { "a" => 1, "b" => [1, 2, 3], "n" => { "x" => true } }
    assert_equal obj, c.load(c.dump(obj))
  end

  def test_nil_passthrough
    assert_nil codec.dump(nil)
    assert_nil codec.load(nil)
  end

  def test_negative_max_output_size_is_rejected
    assert_raises(ArgumentError) { MultiCompress::Codec.new(max_output_size: -1) }
    assert_raises(ArgumentError) { MultiCompress::Codec.new(max_output_size: 0) }
  end

  def test_max_output_size_above_native_range_is_rejected
    too_large = MultiCompress::Codec::MAX_NATIVE_OUTPUT + 1
    error = assert_raises(ArgumentError) { MultiCompress::Codec.new(max_output_size: too_large) }
    assert_match(/at most/, error.message)
  end

  def test_marshal_serializer_roundtrips_binary_payload
    c = codec(serializer: Marshal)
    obj = { a: "\xFF\x00".b, b: [1, 2, 3], c: :sym }
    assert_equal obj, c.load(c.dump(obj))
  end

  def test_invalid_encoding_is_rejected_on_dump_not_read
    assert_raises(ArgumentError) { codec.dump("\xFF\x00".b) }
  end

  def test_binary_encoding_accepts_arbitrary_bytes
    c = codec(encoding: Encoding::BINARY)
    s = "\xFF\x00\x01\x02".b
    assert_equal s, c.load(c.dump(s)).b
  end

  def test_legacy_compressed_uses_dictionary
    samples = Array.new(200) { |i| "event id=#{i} status=ok region=us tag=abc" * 3 }
    dict = MultiCompress::Zstd.train_dictionary(samples, size: 1024)
    raw = MultiCompress.compress(samples.first, algo: :zstd, dictionary: dict)
    c = codec(dictionary: dict, legacy: { compressed: :zstd })
    assert_equal samples.first, c.load(raw)
  end

  def test_base64_legacy_plain_with_mc1_prefix_survives
    c = codec(encode: :base64, legacy: :plain)
    assert_equal "mc1:YWJj", c.load("mc1:YWJj")
  end

  def test_legacy_plain_applies_serializer_symmetrically
    c = codec(serializer: JSON, legacy: :plain)
    assert_equal({ "a" => 1 }, c.load('{"a":1}'))
    assert_equal({ "a" => 1 }, c.load(c.dump({ "a" => 1 })))
  end

  def test_legacy_plain_without_serializer_returns_string
    c = codec(legacy: :plain)
    result = c.load("hello")
    assert_instance_of String, result
    assert_equal Encoding::UTF_8, result.encoding
    assert_equal "hello", result
  end
end
