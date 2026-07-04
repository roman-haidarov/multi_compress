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

  def test_exercises_the_generated_deployment_bundle_on_the_database_host
    assert_includes source, "gem build multi_compress.gemspec"
    assert_includes source, "gem unpack"
    assert_includes source, "db_cli package mysql"
    assert_includes source, "db_cli view mysql"
    assert_includes source, "make verify"
    assert_includes source, "make doctor"
    assert_includes source, "make install"
    assert_includes source, "make enable"
    assert_includes source, "make uninstall CONFIRM=REMOVE_MULTI_COMPRESS"
    assert_includes source, "valid-corrupt-valid scan preserves later valid row"
    assert_includes source, "already enabled; no changes made."
    assert_includes source, "make upgrade CONFIRM=UPGRADE_MULTI_COMPRESS"
    assert_includes source, "foreign_multi_compress.so"
    assert_includes source, "make doctor MYSQL_SOCKET"
    assert_includes source, "install_mysql_build_tools"
    refute_includes source, "copy_mysql_build_tree"
    refute_includes source, "MCDB_UDF_SO"
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
  end

  def test_uses_the_server_plugin_dir_and_committed_adversarial_fixtures
    scripts = File.read(File.join(ROOT, "db_deployment/mysql/bin/common"))
    assert_includes scripts, "SELECT @@plugin_dir;"
    assert_includes scripts, "--protocol=SOCKET"
    assert_includes scripts, "--max_allowed_packet=32M"
    %w[corrupt_magic corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame].each do |name|
      assert_match(/#{name}/, source)
    end
  end
end
