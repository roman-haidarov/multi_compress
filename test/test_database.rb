# frozen_string_literal: true
# encoding: utf-8

require "minitest/autorun"
require "multi_compress/database"

class TestDatabase < Minitest::Test
  D = MultiCompress::Database
  FIX = File.expand_path("fixtures/database_v1", __dir__)

  def test_header_bytes_are_exact
    blob = D.compress("hi")
    header = blob.b.byteslice(0, D::HEADER_SIZE)
    assert_equal "MCDB".b, header.byteslice(0, 4)
    assert_equal 1, header.getbyte(4), "format_version"
    assert_equal 1, header.getbyte(5), "codec = zstd"
    assert_equal 0, header.getbyte(6), "flags reserved = 0"
    assert_equal 2, header.byteslice(7, 8).unpack1("Q<"), "original_size LE"
  end

  def test_original_size_is_utf8_bytesize_not_char_length
    s = "Привет"
    blob = D.compress(s)
    assert_equal s.bytesize, blob.b.byteslice(7, 8).unpack1("Q<")
  end

  def test_header_carries_crc32_of_plaintext
    s = "crc me"
    blob = D.compress(s)
    assert_equal MultiCompress.crc32(s), blob.b.byteslice(15, 4).unpack1("L<")
  end

  def test_crc_mismatch_is_rejected
    blob = D.compress("payload that is fine").dup
    blob.setbyte(15, blob.getbyte(15) ^ 0xFF)
    error = assert_raises(MultiCompress::DataError) { D.decompress(blob) }
    assert_match(/crc32 mismatch/, error.message)
  end

  def test_roundtrip_utf8
    ["", "hello", "Привет", "Сәлем", "emoji 🌍🚀", "x" * 100_000].each do |s|
      out = D.decompress(D.compress(s))
      assert_equal Encoding::UTF_8, out.encoding
      assert_equal s, out
    end
  end

  def test_invalid_utf8_and_nul_are_rejected_on_write
    assert_raises(ArgumentError) { D.compress("\xFF\xFE".b) }
    assert_raises(ArgumentError) { D.compress("text\0with-nul") }
  end

  def test_oversize_rejected_on_write
    huge = "a" * (D::MAX_OUTPUT + 1)
    assert_raises(ArgumentError) { D.compress(huge) }
  end

  def test_oversized_stored_envelope_rejected_on_read
    oversized = D.compress("x") + ("\x00".b * (D::MAX_ENVELOPE))
    error = assert_raises(MultiCompress::DataError) { D.decompress(oversized) }
    assert_match(/over the .*byte limit/, error.message)
  end

  def test_non_string_rejected
    assert_raises(TypeError) { D.compress(123) }
    assert_raises(TypeError) { D.decompress(123) }
  end

  def test_truncated_is_rejected
    assert_raises(MultiCompress::DataError) { D.decompress("MCDB".b) }
  end

  def test_bad_magic_is_rejected
    blob = D.compress("x").dup
    blob.setbyte(0, 0x00)
    assert_raises(MultiCompress::DataError) { D.decompress(blob) }
  end

  def test_wrong_version_is_rejected
    blob = D.compress("x").dup
    blob.setbyte(4, 0x02)
    assert_raises(MultiCompress::DataError) { D.decompress(blob) }
  end

  def test_nonzero_flags_rejected
    blob = D.compress("x").dup
    blob.setbyte(6, 0x01)
    assert_raises(MultiCompress::DataError) { D.decompress(blob) }
  end

  def test_trailing_skippable_frame_is_rejected
    blob = D.compress("single frame only") + [0x184D2A50, 0].pack("L<L<")
    error = assert_raises(MultiCompress::DataError) { D.decompress(blob) }
    assert_match(/exactly one frame|trailing/i, error.message)
  end

  def test_concatenated_zstd_frame_is_rejected
    blob = D.compress("first") + MultiCompress.compress("second", algo: :zstd, level: D::ZSTD_LEVEL)
    error = assert_raises(MultiCompress::DataError) { D.decompress(blob) }
    assert_match(/exactly one frame|trailing/i, error.message)
  end

  def test_corrupt_payload_is_rejected
    blob = D.compress("payload text here").dup
    blob.setbyte(blob.bytesize - 1, blob.getbyte(blob.bytesize - 1) ^ 0xFF)
    assert_raises(MultiCompress::DataError) { D.decompress(blob) }
  end

  def test_size_mismatch_is_rejected
    blob = D.compress("exact size matters").dup
    blob.setbyte(7, blob.getbyte(7) + 1)
    assert_raises(MultiCompress::DataError) { D.decompress(blob) }
  end

  def test_valid_predicate_does_not_raise
    assert D.valid?(D.compress("ok"))
    refute D.valid?("not an envelope at all")
  end

  def test_golden_valid_fixtures_roundtrip
    %w[utf8_text empty_text large_text].each do |name|
      blob = File.binread(File.join(FIX, "#{name}.mcdb"))
      expected = File.binread(File.join(FIX, "#{name}.expected")).force_encoding(Encoding::UTF_8)
      assert_equal expected, D.decompress(blob), "fixture #{name}"
    end
  end

  def test_golden_corrupt_fixtures_are_rejected
    %w[corrupt_magic wrong_version corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame].each do |name|
      blob = File.binread(File.join(FIX, "#{name}.mcdb"))
      assert_raises(MultiCompress::DataError, "fixture #{name} must be rejected") { D.decompress(blob) }
    end
  end
end

class TestDatabaseMcdb2 < Minitest::Test
  D = MultiCompress::Database

  def dictionary
    @dictionary ||= begin
      samples = 256.times.map do |i|
        %({"kind":"event","tenant":#{i % 8},"metadata":{"source":"worker","version":1,"name":"same-shape-#{i % 16}"},"payload":"#{'x' * (48 + i % 64)}"})
      end
      D::Dictionary.train(samples, id: 42, size: 4096)
    end
  end

  def other_dictionary
    @other_dictionary ||= begin
      samples = 256.times.map do |i|
        %({"kind":"other","stream":#{i % 11},"fields":{"different":true,"sequence":#{i}},"body":"#{'y' * (64 + i % 32)}"})
      end
      D::Dictionary.train(samples, id: 43, size: 4096)
    end
  end

  def test_mcdb2_header_is_27_bytes_and_carries_registry_ref
    text = '{"kind":"event","metadata":{"source":"worker"}}'
    blob = D.compress(text, dictionary: dictionary)
    header = blob.byteslice(0, D::V2_HEADER_SIZE)

    assert_equal "MCDB".b, header.byteslice(0, 4)
    assert_equal D::VERSION_V2, header.getbyte(4)
    assert_equal D::CODEC_ZSTD, header.getbyte(5)
    assert_equal D::FLAGS_NONE, header.getbyte(6)
    assert_equal text.bytesize, header.byteslice(D::ORIGINAL_SIZE_OFFSET, 8).unpack1("Q<")
    assert_equal dictionary.id, header.byteslice(D::DICTIONARY_REF_OFFSET, 8).unpack1("Q<")
    assert_equal dictionary.id, D.dictionary_ref(blob)
    assert_equal text.bytesize, D.original_size(blob)
    refute_equal 0, MultiCompress.zstd_frame_dictionary_id(blob.byteslice(D::V2_HEADER_SIZE..))
  end

  def test_mcdb2_round_trip_and_valid_predicate
    text = '{"kind":"event","message":"Привет 🌍","metadata":{"source":"worker"}}'
    blob = D.compress(text, dictionary: dictionary)

    assert_equal text, D.decompress(blob, dictionary: dictionary)
    assert D.valid?(blob, dictionary: dictionary)
    refute D.valid?(blob, dictionary: other_dictionary)
  end

  def test_mcdb2_rejects_wrong_registry_reference_and_wrong_dictionary
    blob = D.compress('{"kind":"event","metadata":{"source":"worker"}}', dictionary: dictionary)

    assert_raises(MultiCompress::DataError) { D.decompress(blob, dictionary: other_dictionary) }
    tampered = blob.dup
    tampered.setbyte(D::DICTIONARY_REF_OFFSET, tampered.getbyte(D::DICTIONARY_REF_OFFSET) ^ 0x01)
    assert_raises(MultiCompress::DataError) { D.decompress(tampered, dictionary: dictionary) }
  end

  def test_mcdb2_dictionary_contract_is_strict
    raw = MultiCompress::Dictionary.new("raw dictionary bytes", algo: :zstd)
    assert_raises(ArgumentError) { D::Dictionary.wrap(raw, id: 1) }
    assert_raises(ArgumentError) { D::Dictionary.wrap(dictionary.native, id: 0) }
    assert_equal 32, dictionary.sha256.bytesize
    assert_equal dictionary.sha256.unpack1("H*"), dictionary.sha256_hex
    assert_equal dictionary.id, dictionary.registry_attributes.fetch(:id)
  end

  def test_mcdb1_remains_dictionary_free
    blob = D.compress("MCDB1 still works")
    assert_equal D::VERSION_V1, blob.getbyte(4)
    assert_equal "MCDB1 still works", D.decompress(blob)
    assert_raises(ArgumentError) { D.decompress(blob, dictionary: dictionary) }
    assert_nil D.dictionary_ref(blob)
  end
end
