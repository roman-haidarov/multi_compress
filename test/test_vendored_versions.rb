# frozen_string_literal: true

require_relative "test_helper"

class TestVendoredVersions < Minitest::Test
  VENDORED_MANIFEST = File.expand_path("../ext/multi_compress/vendor/.vendored", __dir__)

  def test_manifest_pins_zstd_to_1_5_7
    manifest = File.read(VENDORED_MANIFEST)
    versions = manifest.lines(chomp: true).to_h do |line|
      name, version = line.split("=", 2)
      [name, version]
    end

    assert_equal "1.5.7", versions.fetch("zstd")
  end

  def test_runtime_uses_zstd_1_5_7
    assert_equal "1.5.7", MultiCompress.version(:zstd)
  end

  def test_manifest_pins_brotli_to_1_2_0
    manifest = File.read(VENDORED_MANIFEST)
    versions = manifest.lines(chomp: true).to_h do |line|
      name, version = line.split("=", 2)
      [name, version]
    end

    assert_equal "1.2.0", versions.fetch("brotli")
  end

  def test_runtime_uses_brotli_1_2_0
    assert_equal "1.2.0", MultiCompress.version(:brotli)
  end
end
