# frozen_string_literal: true

require_relative "test_helper"

class TestVendoredVersions < Minitest::Test
  VENDORED_MANIFEST = File.expand_path("../ext/multi_compress/vendor/.vendored", __dir__)

  def test_manifest_pins_zstd_to_1_5_2
    manifest = File.read(VENDORED_MANIFEST)
    versions = manifest.lines(chomp: true).to_h do |line|
      name, version = line.split("=", 2)
      [name, version]
    end

    assert_equal "1.5.2", versions.fetch("zstd")
  end

  def test_runtime_uses_zstd_1_5_2
    assert_equal "1.5.2", MultiCompress.version(:zstd)
  end
end
