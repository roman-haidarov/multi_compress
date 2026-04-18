# frozen_string_literal: true

require_relative "test_helper"

class TestLZ4Frame < Minitest::Test
  PAYLOAD = (("frame-data-" * 20_000) + ("\x00\x01\x02\x03" * 10_000)).b.freeze

  def test_lz4_frame_roundtrip_explicit
    compressed = MultiCompress.compress(PAYLOAD, algo: :lz4, format: :frame)

    assert_equal [0x04, 0x22, 0x4D, 0x18], compressed.byteslice(0, 4).bytes
    assert_equal PAYLOAD, MultiCompress.decompress(compressed, algo: :lz4)
    assert_equal PAYLOAD, MultiCompress.lz4_decompress(compressed, format: :frame)
  end

  def test_lz4_frame_autodetect_roundtrip
    compressed = MultiCompress.lz4(PAYLOAD, format: :frame)
    assert_equal PAYLOAD, MultiCompress.decompress(compressed)
  end

  def test_lz4_block_remains_default
    compressed = MultiCompress.compress(PAYLOAD, algo: :lz4)
    refute_equal [0x04, 0x22, 0x4D, 0x18], compressed.byteslice(0, 4).bytes
    assert_equal PAYLOAD, MultiCompress.decompress(compressed, algo: :lz4)
  end

  def test_lz4_frame_corruption_is_detected
    compressed = MultiCompress.compress(PAYLOAD, algo: :lz4, format: :frame).dup
    compressed.setbyte(compressed.bytesize / 2, compressed.getbyte(compressed.bytesize / 2) ^ 0x01)

    assert_raises(MultiCompress::DataError) do
      MultiCompress.decompress(compressed, algo: :lz4, format: :frame)
    end
  end

  def test_lz4_format_is_rejected_for_non_lz4_algorithms
    assert_raises(MultiCompress::UnsupportedError) do
      MultiCompress.compress(PAYLOAD, algo: :zstd, format: :frame)
    end
  end
end
