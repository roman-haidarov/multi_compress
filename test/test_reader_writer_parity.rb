require "minitest/autorun"
require "multi_compress"
require "stringio"

class TestReaderWriterParity < Minitest::Test
  def test_reader_read_length_returns_nil_at_eof
    compressed = MultiCompress.compress("hello world", algo: :zstd)

    MultiCompress::Reader.open(StringIO.new(compressed), algo: :zstd) do |reader|
      assert_equal "hello", reader.read(5)
      assert_equal " worl", reader.read(5)
      assert_equal "d", reader.read(5)
      assert_nil reader.read(5)
    end
  end

  def test_reader_gets_supports_multibyte_separator
    payload = "alpha\r\nbeta\r\ngamma"
    compressed = MultiCompress.compress(payload, algo: :zstd)

    MultiCompress::Reader.open(StringIO.new(compressed), algo: :zstd) do |reader|
      assert_equal "alpha\r\n", reader.gets("\r\n")
      assert_equal "beta\r\n", reader.gets("\r\n")
      assert_equal "gamma", reader.gets("\r\n")
      assert_nil reader.gets("\r\n")
    end
  end

  def test_reader_each_chunk_does_not_yield_empty_string_on_eof
    payload = "abcdefghij"
    compressed = MultiCompress.compress(payload, algo: :zstd)
    chunks = []

    MultiCompress::Reader.open(StringIO.new(compressed), algo: :zstd) do |reader|
      reader.each_chunk(4) { |chunk| chunks << chunk }
    end

    assert_equal ["abcd", "efgh", "ij"], chunks
  end

  def test_writer_puts_flattens_nested_arrays
    io = StringIO.new

    MultiCompress::Writer.open(io, algo: :zstd) do |writer|
      writer.puts([1, [2, 3]])
    end

    decompressed = MultiCompress.decompress(io.string, algo: :zstd)
    assert_equal "1\n2\n3\n", decompressed
  end
end
