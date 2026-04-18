require "minitest/autorun"
require "multi_compress"
require "objspace"

class TestMemsize < Minitest::Test
  def test_dictionary_memsize_grows_after_zstd_warmup
    dict = MultiCompress::Dictionary.new(("dictionary-pattern-" * 512), algo: :zstd)
    payload = ("dictionary-pattern-" * 8_000) + ("payload-" * 4_000)

    before = ObjectSpace.memsize_of(dict)

    compressed = MultiCompress.compress(payload, algo: :zstd, level: 3, dictionary: dict)
    after_compress = ObjectSpace.memsize_of(dict)
    restored = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)
    after_decompress = ObjectSpace.memsize_of(dict)

    assert_equal payload, restored
    assert_operator after_compress, :>, before
    assert_operator after_decompress, :>, after_compress
  end
end
