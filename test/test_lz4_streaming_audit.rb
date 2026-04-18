# frozen_string_literal: true

require_relative "test_helper"

class TestLZ4StreamingAudit < Minitest::Test
  STREAM_CHUNK_SIZE = 128 * 1024

  DATASETS = {
    repeated_pattern: ("ABC123-" * 80_000).b,
    log_like: Array.new(12_000) do |i|
      %Q({"ts":"2026-01-01T00:00:#{(i % 60).to_s.rjust(2, "0")}Z","level":"info","msg":"request #{i}","path":"/v1/items/#{i % 1000}","tenant":"tenant-#{i % 128}"}\n)
    end.join.b,
    random_payload: Random.new(42).bytes(900 * 1024)
  }.freeze

  def lz4_stream(payload)
    deflater = MultiCompress::Deflater.new(algo: :lz4)
    out = +""
    pos = 0
    while pos < payload.bytesize
      out << deflater.write(payload.byteslice(pos, STREAM_CHUNK_SIZE))
      pos += STREAM_CHUNK_SIZE
    end
    out << deflater.finish
    out
  ensure
    deflater&.close
  end

  def explicit_independent_baseline(payload)
    parts = []
    pos = 0
    while pos < payload.bytesize
      piece = payload.byteslice(pos, STREAM_CHUNK_SIZE)
      encoded = MultiCompress.compress(piece, algo: :lz4)
      parts << encoded.byteslice(0, encoded.bytesize - 4)
      pos += STREAM_CHUNK_SIZE
    end
    parts << [0].pack("L<")
    parts.join
  end

  def test_streaming_baselines_roundtrip_and_log_sizes
    DATASETS.each do |name, payload|
      oneshot = MultiCompress.compress(payload, algo: :lz4)
      streaming = lz4_stream(payload)
      explicit = explicit_independent_baseline(payload)

      assert_equal payload, MultiCompress.decompress(oneshot, algo: :lz4), "#{name}: oneshot roundtrip failed"
      assert_equal payload, MultiCompress.decompress(streaming, algo: :lz4), "#{name}: streaming roundtrip failed"
      assert_equal payload, MultiCompress.decompress(explicit, algo: :lz4), "#{name}: explicit independent roundtrip failed"

      warn("[lz4-audit] #{name}: orig=#{payload.bytesize} oneshot=#{oneshot.bytesize} streaming=#{streaming.bytesize} explicit=#{explicit.bytesize}")
    end
  end

  def test_multiblock_streaming_output_autodetects_without_algo
    payload = DATASETS[:log_like] + DATASETS[:repeated_pattern].byteslice(0, 300_000)
    encoded = lz4_stream(payload)
    assert_equal payload, MultiCompress.decompress(encoded)
  end

  def test_multiblock_streaming_output_roundtrips_with_explicit_algo
    payload = DATASETS[:random_payload] + DATASETS[:repeated_pattern].byteslice(0, 300_000)
    encoded = lz4_stream(payload)
    assert_equal payload, MultiCompress.decompress(encoded, algo: :lz4)
  end
end
