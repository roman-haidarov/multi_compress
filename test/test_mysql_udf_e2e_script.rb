# frozen_string_literal: true

require "minitest/autorun"

class TestMysqlUdfE2EScript < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "mysql_udf/test/run_e2e.sh")

  def source
    @source ||= File.binread(SCRIPT).force_encoding(Encoding::UTF_8)
  end

  def test_is_valid_bash
    assert system("bash", "-n", SCRIPT), "run_e2e.sh must pass bash syntax validation"
  end

  def test_defaults_to_pinned_mysql_57_amd64_manifest
    assert_match(
      /DEFAULT_MYSQL_IMAGE="mysql:5\.7\.44@sha256:[0-9a-f]{64}"/,
      source
    )
    assert_match(/PLATFORM="\$\{MCDB_MYSQL_PLATFORM:-linux\/amd64\}"/, source)
    assert_match(/docker run --platform "\$PLATFORM"/, source)
  end

  def test_builds_the_default_udf_inside_the_target_container
    assert_match(/MYSQL_UDF_ABI=mysql57/, source)
    assert_match(/install_mysql_build_tools/, source)
    assert_match(/copy_mysql_build_tree/, source)
    assert_match(/docker cp "\$PWD\/db_core"/, source)
    refute_match(/MCDB_MYSQL_INCLUDE/, source)
  end

  def test_mysql57_compatibility_header_is_complete_and_used
    header = File.read(File.join(ROOT, "mysql_udf/src/mysql_udf_abi_57.h"))
    udf = File.read(File.join(ROOT, "mysql_udf/src/multi_compress_mysql.c"))

    assert_includes header, "typedef char my_bool;"
    assert_includes header, "typedef struct st_udf_args"
    assert_includes header, "typedef struct st_udf_init"
    assert_includes udf, "MCDB_MYSQL_UDF_ABI_57"
    assert_includes udf, "#include <zstd.h>"
    refute_match(/^#ifndef ZSTD_VERSION_STRING$/, udf)
  end

  def test_uses_utf8mb4_and_checks_malformed_values_as_null
    assert_includes source, "--character-set-server=utf8mb4"
    assert_includes source, "--default-character-set=utf8mb4"
    assert_includes source, "CREATE DATABASE app CHARACTER SET utf8mb4"
    assert_includes source, "MySQL connection uses utf8mb4"

    assert_includes source, "for name in corrupt_magic corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame"
    assert_includes source, 'check "$name -> NULL"'
    refute_match(/check_err \"bad magic errors\"/, source)
  end

  def test_uses_the_server_plugin_dir_and_committed_adversarial_fixtures
    assert_match(/SELECT @@plugin_dir;/, source)
    %w[corrupt_magic corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame].each do |name|
      assert_match(/#{name}/, source)
    end
  end
end
