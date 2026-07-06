# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rubygems/package"
require "tmpdir"
require "zlib"

class TestDatabaseDeployment < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXE = File.join(ROOT, "exe", "multi_compress")
  LIB = File.join(ROOT, "lib")

  def run_cli(*args)
    Open3.capture3({ "RUBYLIB" => LIB }, "ruby", EXE, "db", *args)
  end

  def with_tmpdir
    Dir.mktmpdir { |directory| yield directory }
  end

  def tar_entries(path)
    Zlib::GzipReader.open(path) do |gzip|
      Gem::Package::TarReader.new(gzip) { |tar| return tar.map(&:full_name) }
    end
  end

  def test_postgres_package_is_self_contained_and_contains_casual_dba_entrypoints
    with_tmpdir do |directory|
      archive = File.join(directory, "postgres.tar.gz")
      out, err, status = run_cli("package", "postgres", "--output", archive)

      assert_equal 0, status.exitstatus, err
      assert_equal "#{archive}\n", out
      assert File.file?(archive)

      root = "multi_compress-postgres-0.6.0"
      entries = tar_entries(archive)
      %W[
        #{root}/Makefile
        #{root}/README.md
        #{root}/SHA256SUMS
        #{root}/manifest.json
        #{root}/bin/doctor
        #{root}/bin/install
        #{root}/bin/enable
        #{root}/bin/verify
        #{root}/db_core/src/mcdb_format.c
        #{root}/postgres_extension/Makefile
        #{root}/postgres_extension/multi_compress_pg.exports
        #{root}/postgres_extension/src/multi_compress_pg.c
        #{root}/postgres_extension/multi_compress.control
        #{root}/postgres_extension/sql/multi_compress--0.5.0.sql
        #{root}/postgres_extension/sql/multi_compress--0.6.0.sql
        #{root}/postgres_extension/sql/multi_compress--0.5.0--0.6.0.sql
        #{root}/docs/database-envelope-v2.md
        #{root}/docs/rfcs/0002-mcdb2-dictionaries.md
        #{root}/ext/multi_compress/vendor/zstd/lib/zstd.h
        #{root}/THIRD_PARTY_NOTICES.md
      ].each { |entry| assert_includes entries, entry }

      refute entries.any? { |entry| entry.end_with?("multi_compress_pg.so") }
      refute entries.any? { |entry| entry.end_with?(".DS_Store") }
      refute entries.any? { |entry| entry.include?("/build/") }
    end
  end

  def test_mysql_package_contains_source_and_one_command_entrypoints
    with_tmpdir do |directory|
      archive = File.join(directory, "mysql.tar.gz")
      _out, err, status = run_cli("package", "mysql", "--output", archive)

      assert_equal 0, status.exitstatus, err
      root = "multi_compress-mysql-0.6.0"
      entries = tar_entries(archive)
      %W[
        #{root}/Makefile
        #{root}/bin/doctor
        #{root}/bin/install
        #{root}/bin/enable
        #{root}/bin/disable
        #{root}/bin/status
        #{root}/bin/upgrade
        #{root}/THIRD_PARTY_NOTICES.md
        #{root}/mysql_udf/Makefile
        #{root}/mysql_udf/src/multi_compress_mysql.c
        #{root}/mysql_udf/sql/install.sql
        #{root}/db_core/src/mcdb_format.c
        #{root}/ext/multi_compress/vendor/zstd/lib/zstd.h
      ].each { |entry| assert_includes entries, entry }
      refute entries.any? { |entry| entry.end_with?(".DS_Store") }
    end
  end

  def test_postgres_view_sql_is_quoted_and_uses_the_extension_function
    out, err, status = run_cli(
      "view", "postgres",
      "--table", "app.events",
      "--column", "payload_compressed",
      "--view", "admin.events_readable",
      "--columns", "id,created_at,status",
      "--extension-schema", "mc_reader"
    )

    assert_equal 0, status.exitstatus, err
    assert_includes out, 'CREATE OR REPLACE VIEW "admin"."events_readable"'
    assert_includes out, 'source."id"'
    assert_includes out, '"mc_reader".multi_compress_db_decompress(source."payload_compressed") AS "payload"'
    refute_includes out, 'payload_compressed,'
  end

  def test_dictionary_view_sql_uses_inner_join_and_four_argument_decoder
    out, err, status = run_cli(
      "view", "postgres",
      "--table", "app.events",
      "--column", "payload_compressed",
      "--dictionary-table", "app.mcdb_dictionary_versions",
      "--dictionary-id-column", "payload_dictionary_id",
      "--view", "admin.events_readable",
      "--columns", "id"
    )

    assert_equal 0, status.exitstatus, err
    assert_includes out, 'JOIN "app"."mcdb_dictionary_versions" AS dictionary'
    assert_includes out, 'multi_compress_db_decompress_dict(source."payload_compressed", source."payload_dictionary_id", dictionary."sha256", dictionary."bytes")'
    refute_includes out, "LEFT JOIN"
  end

  def test_mysql_dictionary_view_forces_source_first_straight_join
    out, err, status = run_cli(
      "view", "mysql",
      "--table", "app.events",
      "--column", "payload_compressed",
      "--dictionary-table", "app.mcdb_dictionary_versions",
      "--dictionary-id-column", "payload_dictionary_id",
      "--view", "admin.events_readable",
      "--columns", "id"
    )

    assert_equal 0, status.exitstatus, err
    assert_includes out, "CREATE OR REPLACE ALGORITHM=MERGE SQL SECURITY DEFINER VIEW `admin`.`events_readable`"
    assert_includes out, "STRAIGHT_JOIN `app`.`mcdb_dictionary_versions` AS dictionary"
    refute_includes out, "\nJOIN `app`.`mcdb_dictionary_versions`"
  end

  def test_registry_generator_emits_append_only_validation_for_both_targets
    pg, pg_err, pg_status = run_cli(
      "registry", "postgres", "--schema", "app", "--owner", "mcdb_dictionary_owner", "--migration-role", "app_migrations",
      "--payload-table", "events", "--payload-column", "payload_compressed",
      "--payload-dictionary-id-column", "payload_dictionary_id"
    )
    assert_equal 0, pg_status.exitstatus, pg_err
    assert_includes pg, "mcdb_dictionary_version_validate"
    assert_includes pg, "mcdb_dictionary_version_frozen"
    assert_includes pg, "multi_compress_db_dictionary_sha256"
    assert_includes pg, 'OWNER TO "mcdb_dictionary_owner"'
    assert_includes pg, 'GRANT USAGE ON SCHEMA "app" TO "mcdb_dictionary_owner"'
    assert_includes pg, 'multi_compress_db_dictionary_ref(NEW."payload_compressed")'
    assert_includes pg, 'ADD CONSTRAINT "mcdb_payload_dictionary_'

    mysql, mysql_err, mysql_status = run_cli(
      "registry", "mysql", "--database", "app",
      "--payload-table", "events", "--payload-column", "payload_compressed",
      "--payload-dictionary-id-column", "payload_dictionary_id"
    )
    assert_equal 0, mysql_status.exitstatus, mysql_err
    assert_includes mysql, "USE `app`;"
    assert_includes mysql, "BEFORE INSERT ON `mcdb_dictionary_versions`"
    assert_includes mysql, "SIGNAL SQLSTATE '45000'"
    assert_includes mysql, 'multi_compress_db_dictionary_ref(NEW.`payload_compressed`)'
    assert_includes mysql, 'FOREIGN KEY (`payload_dictionary_id`)'
  end

  def test_registry_generator_requires_all_payload_consistency_options_together
    _out, err, status = run_cli(
      "registry", "postgres", "--schema", "app", "--owner", "mcdb_dictionary_owner", "--migration-role", "app_migrations",
      "--payload-table", "events"
    )

    assert_equal 2, status.exitstatus
    assert_match(/must be used together/, err)
  end

  def test_mysql_view_sql_forces_utf8mb4
    out, err, status = run_cli(
      "view", "mysql",
      "--table", "app.events",
      "--column", "payload_compressed",
      "--view", "admin.events_readable",
      "--columns", "id,created_at",
      "--as", "body"
    )

    assert_equal 0, status.exitstatus, err
    assert_includes out, 'CREATE OR REPLACE VIEW `admin`.`events_readable`'
    assert_includes out, 'CONVERT(multi_compress_db_decompress(source.`payload_compressed`) USING utf8mb4) AS `body`'
  end


  def test_view_generator_rejects_duplicate_selected_columns
    _out, err, status = run_cli(
      "view", "postgres",
      "--table", "app.events",
      "--column", "payload_compressed",
      "--view", "admin.events_readable",
      "--columns", "id,id"
    )

    assert_equal 2, status.exitstatus
    assert_match(/must not contain duplicate names/, err)
  end

  def test_view_generator_rejects_decoded_column_collision
    _out, err, status = run_cli(
      "view", "mysql",
      "--table", "app.events",
      "--column", "payload_compressed",
      "--view", "admin.events_readable",
      "--columns", "id,payload",
      "--as", "payload"
    )

    assert_equal 2, status.exitstatus
    assert_match(/must not duplicate a selected column/, err)
  end

  def test_deployment_archives_are_byte_reproducible_with_or_without_source_date_epoch
    with_tmpdir do |directory|
      without_epoch = [File.join(directory, "first.tar.gz"), File.join(directory, "second.tar.gz")]
      with_epoch = [File.join(directory, "epoch-first.tar.gz"), File.join(directory, "epoch-second.tar.gz")]

      without_epoch.each do |archive|
        _out, err, status = Open3.capture3(
          { "RUBYLIB" => LIB, "SOURCE_DATE_EPOCH" => nil },
          "ruby", EXE, "db", "package", "mysql", "--output", archive
        )
        assert_equal 0, status.exitstatus, err
      end
      assert_equal File.binread(without_epoch.first), File.binread(without_epoch.last)

      with_epoch.each do |archive|
        _out, err, status = Open3.capture3(
          { "RUBYLIB" => LIB, "SOURCE_DATE_EPOCH" => "1700000000" },
          "ruby", EXE, "db", "package", "postgres", "--output", archive
        )
        assert_equal 0, status.exitstatus, err
      end
      assert_equal File.binread(with_epoch.first), File.binread(with_epoch.last)
    end
  end

  def test_mysql_doctor_rejects_a_socket_mismatch_even_when_the_reported_plugin_dir_exists_locally
    with_tmpdir do |directory|
      fake_mysql = File.join(directory, "mysql")
      File.write(fake_mysql, <<~SH)
        #!/usr/bin/env bash
        query=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-e" ]; then
            query="$2"
            break
          fi
          shift
        done
        case "$query" in
          *'SELECT VERSION()'*) printf '5.7.44\n' ;;
          *'@@socket'*) printf '/remote/mysqld.sock\n' ;;
          *'@@hostname'*) printf 'remote-host\n' ;;
          *'@@plugin_dir'*) printf '%s\n' "$FAKE_PLUGIN_DIR" ;;
          *'max_allowed_packet'*) printf '33554432\n' ;;
          *) exit 0 ;;
        esac
      SH
      File.chmod(0o755, fake_mysql)

      _out, err, status = Open3.capture3(
        { "MYSQL_SOCKET" => "/local/mysqld.sock", "FAKE_PLUGIN_DIR" => directory },
        File.join(ROOT, "db_deployment/mysql/bin/doctor"), "--mysql", fake_mysql
      )

      assert_equal 2, status.exitstatus
      assert_match(/does not match MYSQL_SOCKET/, err)
    end
  end

  def test_destructive_make_targets_require_exact_confirmation
    [
      ["db_deployment/mysql", "disable"],
      ["db_deployment/mysql", "uninstall"],
      ["db_deployment/mysql", "upgrade"],
      ["db_deployment/postgres", "uninstall"]
    ].each do |directory, target|
      assert_equal false, system("make", "-C", File.join(ROOT, directory), target, out: File::NULL, err: File::NULL)
    end
  end

  def test_mysql_lifecycle_scripts_do_not_auto_drop_and_upgrade_orders_drop_replace_create
    enable = File.read(File.join(ROOT, "db_deployment/mysql/bin/enable"))
    upgrade = File.read(File.join(ROOT, "db_deployment/mysql/bin/upgrade"))

    refute_includes enable, "uninstall.sql"
    assert_includes enable, "already enabled; no changes made"
    assert_includes enable, "MCDB1-only UDF registrations were found"
    assert_includes upgrade, "mcdb_state_is_clean_v1_enabled"
    assert_includes upgrade, "complete MCDB1/MCDB2 UDF surface"
    drop_index = upgrade.index("if ! mcdb_drop_owned_udfs")
    backup_index = upgrade.index('if ! cp -p "$LIBRARY" "$BACKUP"')
    replace_index = upgrade.index('mv -f "$TEMP_LIBRARY" "$LIBRARY"')
    register_index = upgrade.index("if mcdb_register_expected_udfs", replace_index)

    assert_operator drop_index, :<, backup_index
    assert_operator backup_index, :<, replace_index
    assert_operator replace_index, :<, register_index
  end

  def test_deployment_scripts_expose_the_hardened_operational_contract
    mysql_common = File.read(File.join(ROOT, "db_deployment/mysql/bin/common"))
    mysql_doctor = File.read(File.join(ROOT, "db_deployment/mysql/bin/doctor"))
    postgres_enable = File.read(File.join(ROOT, "db_deployment/postgres/bin/enable"))
    postgres_makefile = File.read(File.join(ROOT, "db_deployment/postgres/Makefile"))

    assert_includes mysql_common, "--protocol=SOCKET"
    assert_includes mysql_common, "--max_allowed_packet=32M"
    assert_includes mysql_doctor, "@@GLOBAL.max_allowed_packet"
    assert_includes postgres_enable, "SHOW server_encoding"
    assert_includes postgres_enable, "pg_extension"
    assert_includes postgres_enable, "REVOKE EXECUTE ON ALL FUNCTIONS"
    assert_includes postgres_enable, "ALTER EXTENSION multi_compress UPDATE"
    assert_includes postgres_makefile, "MIGRATION_ROLE"
    assert_includes postgres_makefile, "READ_ROLE"
  end

  def test_view_generator_rejects_sql_injection_shaped_identifiers
    _out, err, status = run_cli(
      "view", "postgres",
      "--table", "app.events;DROP_TABLE",
      "--column", "payload_compressed",
      "--view", "admin.events_readable",
      "--columns", "id"
    )

    assert_equal 2, status.exitstatus
    assert_match(/must be NAME or SCHEMA\.NAME/, err)
    refute_match(/\.rb:\d+:in/, err)
  end

  def test_gem_spec_includes_everything_needed_to_generate_bundles_after_install
    specification = Gem::Specification.load(File.join(ROOT, "multi_compress.gemspec"))

    %w[
      lib/multi_compress/db_deployment.rb
      db_core/src/mcdb_format.c
      postgres_extension/Makefile
      postgres_extension/multi_compress_pg.exports
      mysql_udf/Makefile
      db_deployment/postgres/Makefile
      db_deployment/postgres/bin/install
      db_deployment/mysql/Makefile
      db_deployment/mysql/bin/install
      db_deployment/mysql/bin/status
      db_deployment/mysql/bin/upgrade
      THIRD_PARTY_NOTICES.md
      docs/database-envelope-v2.md
      docs/rfcs/0002-mcdb2-dictionaries.md
    ].each do |path|
      assert_includes specification.files, path
    end
  end

  def test_postgres_installer_keeps_the_simple_pg_config_flow_and_supports_split_paths_for_containerised_builds
    makefile = File.read(File.join(ROOT, "db_deployment", "postgres", "Makefile"))
    installer = File.read(File.join(ROOT, "db_deployment", "postgres", "bin", "install"))

    assert_includes makefile, "PG_CONFIG ?="
    assert_includes makefile, "BUILD_PG_CONFIG ?= $(PG_CONFIG)"
    assert_includes makefile, "RUNTIME_PG_CONFIG ?= $(PG_CONFIG)"
    assert_includes installer, "--build-pg-config"
    assert_includes installer, "--runtime-pg-config"
    assert_includes installer, "does not match runtime major"
  end

  def test_deployment_shell_scripts_are_valid_bash
    Dir.glob(File.join(ROOT, "db_deployment", "*", "bin", "*")).sort.each do |script|
      assert system("bash", "-n", script), "#{script} must pass bash syntax validation"
    end
  end
end
