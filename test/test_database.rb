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
    assert_match(/envelope too large/, error.message)
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
