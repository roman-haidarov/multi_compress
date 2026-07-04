# frozen_string_literal: true

require "minitest/autorun"

class TestPostgresExtensionFiles < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PG = File.join(ROOT, "postgres_extension")

  def read(relative)
    File.read(File.join(PG, relative))
  end

  def test_extension_package_has_required_files
    %w[
      Makefile
      README.md
      multi_compress.control
      multi_compress_pg.exports
      src/multi_compress_pg.c
      src/mcdb_format.c
      sql/multi_compress--0.5.0.sql
      sql/uninstall.sql
      sql/views.sql
      sql/examples.sql
      test/run_e2e.sh
    ].each do |relative|
      assert File.file?(File.join(PG, relative)), "missing postgres_extension/#{relative}"
    end
  end

  def test_control_and_sql_expose_the_three_public_functions
    control = read("multi_compress.control")
    sql = read("sql/multi_compress--0.5.0.sql")

    assert_includes control, "default_version = '0.5.0'"
    assert_includes control, "module_pathname = '$libdir/multi_compress_pg'"
    assert_includes sql, "CREATE FUNCTION multi_compress_db_version()"
    assert_includes sql, "CREATE FUNCTION multi_compress_db_is_valid(blob bytea)"
    assert_includes sql, "CREATE FUNCTION multi_compress_db_decompress(blob bytea)"
    assert_includes sql, "STRICT"
    assert_includes sql, "PARALLEL SAFE"
  end

  def test_extension_uses_shared_core_and_utf8_database_guard
    core_wrapper = read("src/mcdb_format.c")
    source = read("src/multi_compress_pg.c")

    assert_includes core_wrapper, '../../db_core/src/mcdb_format.c'
    assert_includes source, "PG_MODULE_MAGIC"
    assert_includes source, "GetDatabaseEncoding() != PG_UTF8"
    assert_includes source, "#include \"varatt.h\""
    assert_includes source, "(void)fcinfo;"
    assert_includes source, "MCDB_ERR"
  end

  def test_makefile_links_vendored_zstd_archive_without_exposing_its_objects_to_pgxs
    makefile = read("Makefile")

    assert_match(/^OBJS\s*=\s*src\/multi_compress_pg\.o\s+src\/mcdb_format\.o\s*$/, makefile)
    assert_includes makefile, "--version-script=$(EXPORT_MAP)"
    refute_match(/^OBJS[^\n]*\$\(ZSTD_OBJS\)/, makefile)

    exports = read("multi_compress_pg.exports")
    %w[
      Pg_magic_func
      pg_finfo_multi_compress_db_version
      pg_finfo_multi_compress_db_is_valid
      pg_finfo_multi_compress_db_decompress
      multi_compress_db_version
      multi_compress_db_is_valid
      multi_compress_db_decompress
    ].each { |symbol| assert_includes exports, symbol }
    assert_includes exports, "local:"
    assert_includes exports, "*;"
  end

  def test_e2e_runs_the_generated_deployment_bundle_and_generated_view
    script = read("test/run_e2e.sh")

    assert_includes script, "postgres:17.9-bookworm@sha256:"
    assert_includes script, "--platform"
    assert_includes script, "gem build multi_compress.gemspec"
    assert_includes script, "gem unpack"
    assert_includes script, "db_cli package postgres"
    assert_includes script, "db_cli view postgres"
    assert_includes script, "make verify"
    assert_includes script, "make doctor PG_CONFIG"
    assert_includes script, "make install BUILD_PG_CONFIG"
    assert_includes script, "make enable DB=postgres MIGRATION_ROLE=app_migrations READ_ROLE=dbeaver_readonly"
    assert_includes script, "make uninstall CONFIRM=REMOVE_MULTI_COMPRESS"
    assert_includes script, "CREATE DATABASE mcdb_latin1"
    assert_includes script, "mcdb_other_schema"
    assert_includes script, "read role reads generated Unicode view"
    assert_includes script, "generated readable view"
    assert_includes script, "trap cleanup EXIT"
    refute_includes script, "copy_postgres_build_tree"
    refute_includes script, "MCDB_PG_SO"
  end
end
