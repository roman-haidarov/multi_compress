# frozen_string_literal: true

require "multi_compress/version"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "rubygems/package"
require "securerandom"
require "tmpdir"
require "zlib"

module MultiCompress
  module DBDeployment
    ROOT = File.expand_path("../..", __dir__)
    FORMAT = "MCDB1 + MCDB2"
    BUNDLE_FORMAT_VERSION = 2
    MAX_DICTIONARY_BYTES = 256 * 1024

    class Error < StandardError; end

    class CLI
      def self.run(argv)
        new.run(argv)
      end

      def run(argv)
        command = argv.shift

        case command
        when "package"
          PackageCommand.new.run(argv)
        when "view"
          ViewCommand.new.run(argv)
        when "registry"
          RegistryCommand.new.run(argv)
        when "help", "--help", "-h", nil
          puts help
          0
        else
          raise OptionParser::InvalidOption, "unknown db command: #{command.inspect}"
        end
      rescue OptionParser::ParseError, Error => e
        warn "multi_compress db: #{e.message}"
        2
      rescue SystemCallError, IOError => e
        warn "multi_compress db: #{e.message}"
        1
      end

      private

      def help
        <<~TEXT
          Usage:
            multi_compress db package postgres [--output PATH] [--force]
            multi_compress db package mysql    [--output PATH] [--force]

            multi_compress db view postgres --table SCHEMA.TABLE --column COLUMN \\
              --view SCHEMA.VIEW --columns ID,CREATED_AT [--as PAYLOAD] \\
              [--extension-schema multi_compress] [--output PATH]

            multi_compress db view mysql --table SCHEMA.TABLE --column COLUMN \\
              --view SCHEMA.VIEW --columns ID,CREATED_AT [--as PAYLOAD] [--output PATH]

          `package` creates a self-contained source bundle for the DBA. The DBA
          extracts it on the database host and runs `make doctor`, `sudo make
          install`, then `make enable DB=...`.

          `view` emits a safe readable-view definition so DBeaver users query
          decoded text instead of the compressed bytea/BLOB column. Supply
          --dictionary-table and --dictionary-id-column for MCDB2.

          `registry` emits append-only MCDB2 dictionary-registry DDL. Dictionary
          bytes are application data and are never placed in a DBA reader bundle.
          Supplying --payload-table, --payload-column and
          --payload-dictionary-id-column also emits the MCDB2 header/FK
          consistency trigger for that source table.
        TEXT
      end
    end

    class PackageCommand
      TARGETS = %w[postgres mysql].freeze

      def run(argv)
        target = argv.shift
        raise OptionParser::MissingArgument, "TARGET must be postgres or mysql" if target.nil?
        raise OptionParser::InvalidArgument, "TARGET must be postgres or mysql" unless TARGETS.include?(target)

        options = { output: nil, force: false }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: multi_compress db package #{target} [OPTIONS]"
          opts.on("-o", "--output PATH", "write the deployment archive to PATH") { |value| options[:output] = value }
          opts.on("-f", "--force", "overwrite an existing archive") { options[:force] = true }
          opts.on("-h", "--help", "show this help") { puts opts; return 0 }
        end
        parser.parse!(argv)
        raise OptionParser::InvalidOption, argv.join(" ") unless argv.empty?

        output = options[:output] || "multi_compress-#{target}-#{MultiCompress::VERSION}.tar.gz"
        DeploymentBundle.new(target, output, force: options[:force]).write!
        puts File.expand_path(output)
        0
      end
    end

    class ViewCommand
      TARGETS = %w[postgres mysql].freeze
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

      def run(argv)
        target = argv.shift
        raise OptionParser::MissingArgument, "TARGET must be postgres or mysql" if target.nil?
        raise OptionParser::InvalidArgument, "TARGET must be postgres or mysql" unless TARGETS.include?(target)

        options = {
          columns: [], as: "payload", output: nil, extension_schema: "multi_compress",
          dictionary_table: nil, dictionary_id_column: nil,
          registry_id_column: "id", dictionary_sha256_column: "sha256",
          dictionary_bytes_column: "bytes"
        }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: multi_compress db view #{target} --table SCHEMA.TABLE --column COLUMN --view SCHEMA.VIEW --columns ID,CREATED_AT [OPTIONS]"
          opts.on("--table NAME", "source table, optionally schema-qualified") { |value| options[:table] = value }
          opts.on("--column NAME", "compressed bytea/BLOB column") { |value| options[:column] = value }
          opts.on("--view NAME", "destination view, optionally schema-qualified") { |value| options[:view] = value }
          opts.on("--columns LIST", "comma-separated plain columns to expose") { |value| options[:columns] = value.split(",").map(&:strip) }
          opts.on("--as NAME", "decoded column name (default: payload)") { |value| options[:as] = value }
          opts.on("--dictionary-table NAME", "MCDB2 immutable dictionary registry table") { |value| options[:dictionary_table] = value }
          opts.on("--dictionary-id-column NAME", "MCDB2 FK column on source table") { |value| options[:dictionary_id_column] = value }
          opts.on("--registry-id-column NAME", "registry PK (default: id)") { |value| options[:registry_id_column] = value }
          opts.on("--dictionary-sha256-column NAME", "registry SHA-256 column (default: sha256)") { |value| options[:dictionary_sha256_column] = value }
          opts.on("--dictionary-bytes-column NAME", "registry dictionary bytes column (default: bytes)") { |value| options[:dictionary_bytes_column] = value }
          if target == "postgres"
            opts.on("--extension-schema NAME", "extension schema (default: multi_compress)") { |value| options[:extension_schema] = value }
          end
          opts.on("-o", "--output PATH", "write SQL to PATH instead of stdout") { |value| options[:output] = value }
          opts.on("-h", "--help", "show this help") { puts opts; return 0 }
        end
        parser.parse!(argv)
        raise OptionParser::InvalidOption, argv.join(" ") unless argv.empty?

        sql = ReadableView.new(target, options).to_sql
        if options[:output]
          write_text_atomically(options[:output], sql)
          puts File.expand_path(options[:output])
        else
          $stdout.write(sql)
        end
        0
      end

      private

      def write_text_atomically(path, contents)
        directory = File.dirname(File.expand_path(path))
        FileUtils.mkdir_p(directory)
        temporary = File.join(directory, ".multi-compress-view-#{Process.pid}-#{SecureRandom.hex(8)}")
        File.open(temporary, "wb", 0o644) { |file| file.write(contents) }
        File.rename(temporary, path)
      ensure
        File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
      end
    end

    class RegistryCommand
      TARGETS = %w[postgres mysql].freeze
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

      def run(argv)
        target = argv.shift
        raise OptionParser::MissingArgument, "TARGET must be postgres or mysql" if target.nil?
        raise OptionParser::InvalidArgument, "TARGET must be postgres or mysql" unless TARGETS.include?(target)

        options = { output: nil, extension_schema: "multi_compress", table: "mcdb_dictionary_versions", heads_table: "mcdb_dictionary_heads" }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: multi_compress db registry #{target} [OPTIONS]"
          if target == "postgres"
            opts.on("--schema NAME", "application schema") { |value| options[:schema] = value }
            opts.on("--owner ROLE", "NOLOGIN owner for append-only dictionary versions") { |value| options[:owner] = value }
            opts.on("--migration-role ROLE", "role allowed to insert dictionary versions") { |value| options[:migration_role] = value }
            opts.on("--extension-schema NAME", "extension schema (default: multi_compress)") { |value| options[:extension_schema] = value }
          else
            opts.on("--database NAME", "application database") { |value| options[:schema] = value }
          end
          opts.on("--table NAME", "versions table (default: mcdb_dictionary_versions)") { |value| options[:table] = value }
          opts.on("--heads-table NAME", "heads table (default: mcdb_dictionary_heads)") { |value| options[:heads_table] = value }
          opts.on("--payload-table NAME", "MCDB2 source table in this schema/database") { |value| options[:payload_table] = value }
          opts.on("--payload-column NAME", "MCDB2 compressed envelope column on --payload-table") { |value| options[:payload_column] = value }
          opts.on("--payload-dictionary-id-column NAME", "MCDB2 dictionary FK column on --payload-table") { |value| options[:payload_dictionary_id_column] = value }
          opts.on("-o", "--output PATH", "write SQL to PATH instead of stdout") { |value| options[:output] = value }
          opts.on("-h", "--help", "show this help") { puts opts; return 0 }
        end
        parser.parse!(argv)
        raise OptionParser::InvalidOption, argv.join(" ") unless argv.empty?
        sql = DictionaryRegistry.new(target, options).to_sql
        if options[:output]
          ViewCommand.new.send(:write_text_atomically, options[:output], sql)
          puts File.expand_path(options[:output])
        else
          $stdout.write(sql)
        end
        0
      end
    end

    class DictionaryRegistry
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

      def initialize(target, options)
        @target = target
        @schema = identifier!(options.fetch(:schema), target == "postgres" ? "--schema" : "--database")
        @table = identifier!(options.fetch(:table), "--table")
        @heads_table = identifier!(options.fetch(:heads_table), "--heads-table")
        @owner = options[:owner] && identifier!(options[:owner], "--owner")
        @migration_role = options[:migration_role] && identifier!(options[:migration_role], "--migration-role")
        @extension_schema = identifier!(options.fetch(:extension_schema, "multi_compress"), "--extension-schema")
        @payload_table = options[:payload_table] && identifier!(options[:payload_table], "--payload-table")
        @payload_column = options[:payload_column] && identifier!(options[:payload_column], "--payload-column")
        @payload_dictionary_id_column = options[:payload_dictionary_id_column] && identifier!(options[:payload_dictionary_id_column], "--payload-dictionary-id-column")
        payload_options = [@payload_table, @payload_column, @payload_dictionary_id_column]
        unless payload_options.all? || payload_options.none?
          raise Error, "--payload-table, --payload-column and --payload-dictionary-id-column must be used together"
        end
        if @target == "postgres" && (!@owner || !@migration_role)
          raise Error, "--owner and --migration-role are required for postgres registry DDL"
        end
      rescue KeyError
        raise Error, @target == "postgres" ? "--schema, --owner and --migration-role are required" : "--database is required"
      end

      def to_sql
        @target == "postgres" ? postgres_sql : mysql_sql
      end

      private

      def postgres_sql
        q = method(:pg_quote)
        schema = q.call(@schema)
        table = q.call(@table)
        heads = q.call(@heads_table)
        ext = q.call(@extension_schema)
        <<~SQL
          -- Generated by multi_compress #{MultiCompress::VERSION}. Apply as a privileged migration/DBA role.
          -- The owner role must be a pre-existing NOLOGIN role. Dictionary bytes are append-only application data.
          CREATE TABLE #{schema}.#{table} (
            id bigint PRIMARY KEY CHECK (id > 0),
            family text NOT NULL,
            zstd_dict_id bigint NOT NULL CHECK (zstd_dict_id > 0),
            sha256 bytea NOT NULL UNIQUE CHECK (octet_length(sha256) = 32),
            bytes bytea NOT NULL CHECK (octet_length(bytes) BETWEEN 1 AND #{MAX_DICTIONARY_BYTES}),
            created_at timestamptz NOT NULL DEFAULT now()
          );
          ALTER TABLE #{schema}.#{table} OWNER TO #{q.call(@owner)};
          -- PostgreSQL RI triggers execute the FK lookup under the relation owner.
          -- A NOLOGIN owner therefore still needs schema USAGE for the payload FK.
          GRANT USAGE ON SCHEMA #{schema} TO #{q.call(@owner)};

          CREATE TABLE #{schema}.#{heads} (
            family text PRIMARY KEY,
            dictionary_id bigint NOT NULL REFERENCES #{schema}.#{table}(id) ON DELETE RESTRICT
          );
          ALTER TABLE #{schema}.#{heads} OWNER TO #{q.call(@owner)};

          CREATE FUNCTION #{schema}.mcdb_dictionary_version_validate() RETURNS trigger
          LANGUAGE plpgsql AS $$
          BEGIN
            IF NEW.id <= 0 OR NEW.zstd_dict_id <= 0 OR octet_length(NEW.sha256) <> 32 THEN
              RAISE EXCEPTION 'invalid MCDB2 dictionary metadata';
            END IF;
            IF NEW.sha256 IS DISTINCT FROM #{ext}.multi_compress_db_dictionary_sha256(NEW.bytes) THEN
              RAISE EXCEPTION 'MCDB2 dictionary sha256 does not match bytes';
            END IF;
            IF NEW.zstd_dict_id IS DISTINCT FROM #{ext}.multi_compress_db_dictionary_zstd_id(NEW.bytes) THEN
              RAISE EXCEPTION 'MCDB2 zstd dictionary id does not match bytes';
            END IF;
            RETURN NEW;
          END $$;
          ALTER FUNCTION #{schema}.mcdb_dictionary_version_validate() OWNER TO #{q.call(@owner)};

          CREATE FUNCTION #{schema}.mcdb_dictionary_version_frozen() RETURNS trigger
          LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'MCDB dictionary versions are append-only'; END $$;
          ALTER FUNCTION #{schema}.mcdb_dictionary_version_frozen() OWNER TO #{q.call(@owner)};

          CREATE TRIGGER mcdb_dictionary_version_validate
            BEFORE INSERT ON #{schema}.#{table}
            FOR EACH ROW EXECUTE FUNCTION #{schema}.mcdb_dictionary_version_validate();
          CREATE TRIGGER mcdb_dictionary_version_frozen
            BEFORE UPDATE OR DELETE ON #{schema}.#{table}
            FOR EACH ROW EXECUTE FUNCTION #{schema}.mcdb_dictionary_version_frozen();

          REVOKE ALL ON #{schema}.#{table}, #{schema}.#{heads} FROM PUBLIC;
          GRANT SELECT, INSERT ON #{schema}.#{table} TO #{q.call(@migration_role)};
          GRANT SELECT, INSERT, UPDATE, DELETE ON #{schema}.#{heads} TO #{q.call(@migration_role)};
          #{postgres_payload_consistency_sql}
        SQL
      end

      def mysql_sql
        schema = mysql_quote(@schema)
        table = mysql_quote(@table)
        heads = mysql_quote(@heads_table)
        <<~SQL
          -- Generated by multi_compress #{MultiCompress::VERSION}. MySQL 5.7 registry DDL.
          -- Apply this in the application database. Dictionary versions are append-only.
          USE #{schema};
          CREATE TABLE #{table} (
            id BIGINT UNSIGNED NOT NULL,
            family VARCHAR(191) NOT NULL,
            zstd_dict_id BIGINT UNSIGNED NOT NULL,
            sha256 BINARY(32) NOT NULL,
            bytes LONGBLOB NOT NULL,
            created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
            PRIMARY KEY (id),
            UNIQUE KEY mcdb_dictionary_versions_sha256 (sha256)
          ) ENGINE=InnoDB;
          CREATE TABLE #{heads} (
            family VARCHAR(191) NOT NULL,
            dictionary_id BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (family),
            CONSTRAINT mcdb_dictionary_heads_dictionary_fk
              FOREIGN KEY (dictionary_id) REFERENCES #{table}(id) ON DELETE RESTRICT
          ) ENGINE=InnoDB;

          DELIMITER //
          CREATE TRIGGER #{mysql_quote("#{@table}_validate")}
          BEFORE INSERT ON #{table} FOR EACH ROW
          BEGIN
            IF NEW.id = 0 OR NEW.id > 9223372036854775807 OR NEW.zstd_dict_id = 0 OR OCTET_LENGTH(NEW.sha256) <> 32 OR
               OCTET_LENGTH(NEW.bytes) = 0 OR OCTET_LENGTH(NEW.bytes) > #{MAX_DICTIONARY_BYTES} OR
               NOT (NEW.sha256 <=> multi_compress_db_dictionary_sha256(NEW.bytes)) OR
               NOT (NEW.zstd_dict_id <=> multi_compress_db_dictionary_zstd_id(NEW.bytes)) THEN
              SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'invalid MCDB2 dictionary metadata';
            END IF;
          END//
          CREATE TRIGGER #{mysql_quote("#{@table}_frozen_update")}
          BEFORE UPDATE ON #{table} FOR EACH ROW
          BEGIN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'MCDB dictionary versions are append-only'; END//
          CREATE TRIGGER #{mysql_quote("#{@table}_frozen_delete")}
          BEFORE DELETE ON #{table} FOR EACH ROW
          BEGIN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'MCDB dictionary versions are append-only'; END//
          #{mysql_payload_consistency_sql}
          DELIMITER ;
        SQL
      end

      def payload_consistency?
        !@payload_table.nil?
      end

      def payload_consistency_token
        Digest::SHA256.hexdigest([@schema, @payload_table, @payload_column, @payload_dictionary_id_column].join("\0"))[0, 12]
      end

      def postgres_payload_consistency_sql
        return "" unless payload_consistency?

        q = method(:pg_quote)
        token = payload_consistency_token
        function_name = "mcdb_payload_ref_#{token}"
        trigger_name = "mcdb_payload_ref_#{token}_check"
        <<~SQL

          ALTER TABLE #{q.call(@schema)}.#{q.call(@payload_table)}
            ADD CONSTRAINT #{q.call("mcdb_payload_dictionary_#{token}_fk")}
            FOREIGN KEY (#{q.call(@payload_dictionary_id_column)})
            REFERENCES #{q.call(@schema)}.#{q.call(@table)}(id) ON DELETE RESTRICT;

          CREATE FUNCTION #{q.call(@schema)}.#{q.call(function_name)}() RETURNS trigger
          LANGUAGE plpgsql AS $$
          BEGIN
            IF NEW.#{q.call(@payload_column)} IS NULL OR NEW.#{q.call(@payload_dictionary_id_column)} IS NULL OR
               #{q.call(@extension_schema)}.multi_compress_db_dictionary_ref(NEW.#{q.call(@payload_column)}) IS DISTINCT FROM NEW.#{q.call(@payload_dictionary_id_column)} THEN
              RAISE EXCEPTION 'MCDB2 payload dictionary reference must match its dictionary FK';
            END IF;
            RETURN NEW;
          END $$;
          ALTER FUNCTION #{q.call(@schema)}.#{q.call(function_name)}() OWNER TO #{q.call(@owner)};
          CREATE TRIGGER #{q.call(trigger_name)}
            BEFORE INSERT OR UPDATE OF #{q.call(@payload_column)}, #{q.call(@payload_dictionary_id_column)}
            ON #{q.call(@schema)}.#{q.call(@payload_table)}
            FOR EACH ROW EXECUTE FUNCTION #{q.call(@schema)}.#{q.call(function_name)}();
        SQL
      end

      def mysql_payload_consistency_sql
        return "" unless payload_consistency?

        token = payload_consistency_token
        insert_trigger = mysql_quote("mcdb_payload_ref_#{token}_insert")
        update_trigger = mysql_quote("mcdb_payload_ref_#{token}_update")
        payload_table = mysql_quote(@payload_table)
        payload_column = mysql_quote(@payload_column)
        payload_ref_column = mysql_quote(@payload_dictionary_id_column)
        <<~SQL

          ALTER TABLE #{payload_table}
            ADD CONSTRAINT #{mysql_quote("mcdb_payload_dictionary_#{token}_fk")}
            FOREIGN KEY (#{payload_ref_column}) REFERENCES #{mysql_quote(@table)}(id) ON DELETE RESTRICT;
          CREATE TRIGGER #{insert_trigger}
          BEFORE INSERT ON #{payload_table} FOR EACH ROW
          BEGIN
            IF NEW.#{payload_column} IS NULL OR NEW.#{payload_ref_column} IS NULL OR
               NOT (multi_compress_db_dictionary_ref(NEW.#{payload_column}) <=> NEW.#{payload_ref_column}) THEN
              SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'MCDB2 payload dictionary reference must match its dictionary FK';
            END IF;
          END//
          CREATE TRIGGER #{update_trigger}
          BEFORE UPDATE ON #{payload_table} FOR EACH ROW
          BEGIN
            IF NEW.#{payload_column} IS NULL OR NEW.#{payload_ref_column} IS NULL OR
               NOT (multi_compress_db_dictionary_ref(NEW.#{payload_column}) <=> NEW.#{payload_ref_column}) THEN
              SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'MCDB2 payload dictionary reference must match its dictionary FK';
            END IF;
          END//
        SQL
      end

      def identifier!(value, option)
        string = value.to_s
        raise Error, "#{option} must use letters, digits and underscores and cannot start with a digit" unless IDENTIFIER.match?(string)
        string
      end

      def pg_quote(identifier)
        %Q("#{identifier}")
      end

      def mysql_quote(identifier)
        "`#{identifier}`"
      end
    end

    class ReadableView
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

      def initialize(target, options)
        @target = target
        @table = qualified_identifier!(options.fetch(:table), "--table")
        @view = qualified_identifier!(options.fetch(:view), "--view")
        @column = identifier!(options.fetch(:column), "--column")
        @columns = Array(options.fetch(:columns)).reject(&:empty?).map { |value| identifier!(value, "--columns") }
        @decoded_name = identifier!(options.fetch(:as), "--as")
        @extension_schema = identifier!(options.fetch(:extension_schema, "multi_compress"), "--extension-schema")
        @dictionary_table = options[:dictionary_table] && qualified_identifier!(options[:dictionary_table], "--dictionary-table")
        @dictionary_id_column = options[:dictionary_id_column] && identifier!(options[:dictionary_id_column], "--dictionary-id-column")
        @registry_id_column = identifier!(options.fetch(:registry_id_column, "id"), "--registry-id-column")
        @dictionary_sha256_column = identifier!(options.fetch(:dictionary_sha256_column, "sha256"), "--dictionary-sha256-column")
        @dictionary_bytes_column = identifier!(options.fetch(:dictionary_bytes_column, "bytes"), "--dictionary-bytes-column")
        if !!@dictionary_table != !!@dictionary_id_column
          raise Error, "--dictionary-table and --dictionary-id-column must be used together for MCDB2"
        end
        raise Error, "--columns must contain at least one plain column" if @columns.empty?
        raise Error, "--columns must not contain duplicate names" unless @columns.uniq.length == @columns.length
        raise Error, "--as must not duplicate a selected column" if @columns.include?(@decoded_name)
      rescue KeyError
        raise Error, "--table, --column, --view and --columns are required"
      end

      def to_sql
        case @target
        when "postgres" then postgres_sql
        when "mysql" then mysql_sql
        else raise Error, "unsupported database target: #{@target.inspect}"
        end
      end

      private

      def postgres_sql
        selections = @columns.map { |column| "  source.#{pg_quote(column)}" }
        selections << "  #{postgres_decoder_sql} AS #{pg_quote(@decoded_name)}"

        <<~SQL
          -- Generated by multi_compress #{MultiCompress::VERSION}. Keep this view in your schema migrations.
          -- Query it in DBeaver; do not expose the compressed column or dictionary registry directly.
          CREATE OR REPLACE VIEW #{pg_qualified(@view)} AS
          SELECT
          #{selections.join(",\n")}
          FROM #{pg_qualified(@table)} AS source#{postgres_dictionary_join};
        SQL
      end

      def mysql_sql
        selections = @columns.map { |column| "  source.#{mysql_quote(column)}" }
        selections << "  CONVERT(#{mysql_decoder_sql} USING utf8mb4) AS #{mysql_quote(@decoded_name)}"
        algorithm = dictionary? ? " ALGORITHM=MERGE SQL SECURITY DEFINER" : ""

        <<~SQL
          -- Generated by multi_compress #{MultiCompress::VERSION}. Keep this view in your schema migrations.
          -- Query it in DBeaver; do not expose the compressed column or dictionary registry directly.
          -- MCDB2 requires this view to remain MERGE-able: no DISTINCT/GROUP BY/UNION/aggregate/subquery/LIMIT.
          CREATE OR REPLACE#{algorithm} VIEW #{mysql_qualified(@view)} AS
          SELECT
          #{selections.join(",\n")}
          FROM #{mysql_qualified(@table)} AS source#{mysql_dictionary_join};
        SQL
      end

      def dictionary?
        !@dictionary_table.nil?
      end

      def postgres_decoder_sql
        return "#{pg_quote(@extension_schema)}.multi_compress_db_decompress(source.#{pg_quote(@column)})" unless dictionary?

        "#{pg_quote(@extension_schema)}.multi_compress_db_decompress_dict(" \
          "source.#{pg_quote(@column)}, source.#{pg_quote(@dictionary_id_column)}, " \
          "dictionary.#{pg_quote(@dictionary_sha256_column)}, dictionary.#{pg_quote(@dictionary_bytes_column)})"
      end

      def mysql_decoder_sql
        return "multi_compress_db_decompress(source.#{mysql_quote(@column)})" unless dictionary?

        "multi_compress_db_decompress_dict(" \
          "source.#{mysql_quote(@column)}, source.#{mysql_quote(@dictionary_id_column)}, " \
          "dictionary.#{mysql_quote(@dictionary_sha256_column)}, dictionary.#{mysql_quote(@dictionary_bytes_column)})"
      end

      def postgres_dictionary_join
        return "" unless dictionary?

        "\nJOIN #{pg_qualified(@dictionary_table)} AS dictionary ON dictionary.#{pg_quote(@registry_id_column)} = source.#{pg_quote(@dictionary_id_column)}"
      end

      def mysql_dictionary_join
        return "" unless dictionary?

        # MySQL 5.7 may otherwise start from the tiny registry and then examine a
        # broad source set. The generated view always places source on the left, so
        # STRAIGHT_JOIN preserves source-first predicate pushdown before dictionary
        # lookup. An outer ORDER BY can still legitimately report filesort; that is
        # distinct from a materialized view (<derived...> in EXPLAIN).
        "\nSTRAIGHT_JOIN #{mysql_qualified(@dictionary_table)} AS dictionary ON dictionary.#{mysql_quote(@registry_id_column)} = source.#{mysql_quote(@dictionary_id_column)}"
      end

      def qualified_identifier!(value, option)
        pieces = value.to_s.split(".", -1)
        unless pieces.length.between?(1, 2) && pieces.all? { |piece| IDENTIFIER.match?(piece) }
          raise Error, "#{option} must be NAME or SCHEMA.NAME using letters, digits and underscores"
        end
        pieces
      end

      def payload_consistency?
        !@payload_table.nil?
      end

      def payload_consistency_token
        Digest::SHA256.hexdigest([@schema, @payload_table, @payload_column, @payload_dictionary_id_column].join("\0"))[0, 12]
      end

      def postgres_payload_consistency_sql
        return "" unless payload_consistency?

        q = method(:pg_quote)
        token = payload_consistency_token
        function_name = "mcdb_payload_ref_#{token}"
        trigger_name = "mcdb_payload_ref_#{token}_check"
        <<~SQL

          ALTER TABLE #{q.call(@schema)}.#{q.call(@payload_table)}
            ADD CONSTRAINT #{q.call("mcdb_payload_dictionary_#{token}_fk")}
            FOREIGN KEY (#{q.call(@payload_dictionary_id_column)})
            REFERENCES #{q.call(@schema)}.#{q.call(@table)}(id) ON DELETE RESTRICT;

          CREATE FUNCTION #{q.call(@schema)}.#{q.call(function_name)}() RETURNS trigger
          LANGUAGE plpgsql AS $$
          BEGIN
            IF NEW.#{q.call(@payload_column)} IS NULL OR NEW.#{q.call(@payload_dictionary_id_column)} IS NULL OR
               #{q.call(@extension_schema)}.multi_compress_db_dictionary_ref(NEW.#{q.call(@payload_column)}) IS DISTINCT FROM NEW.#{q.call(@payload_dictionary_id_column)} THEN
              RAISE EXCEPTION 'MCDB2 payload dictionary reference must match its dictionary FK';
            END IF;
            RETURN NEW;
          END $$;
          ALTER FUNCTION #{q.call(@schema)}.#{q.call(function_name)}() OWNER TO #{q.call(@owner)};
          CREATE TRIGGER #{q.call(trigger_name)}
            BEFORE INSERT OR UPDATE OF #{q.call(@payload_column)}, #{q.call(@payload_dictionary_id_column)}
            ON #{q.call(@schema)}.#{q.call(@payload_table)}
            FOR EACH ROW EXECUTE FUNCTION #{q.call(@schema)}.#{q.call(function_name)}();
        SQL
      end

      def mysql_payload_consistency_sql
        return "" unless payload_consistency?

        token = payload_consistency_token
        insert_trigger = mysql_quote("mcdb_payload_ref_#{token}_insert")
        update_trigger = mysql_quote("mcdb_payload_ref_#{token}_update")
        payload_table = mysql_quote(@payload_table)
        payload_column = mysql_quote(@payload_column)
        payload_ref_column = mysql_quote(@payload_dictionary_id_column)
        <<~SQL

          ALTER TABLE #{payload_table}
            ADD CONSTRAINT #{mysql_quote("mcdb_payload_dictionary_#{token}_fk")}
            FOREIGN KEY (#{payload_ref_column}) REFERENCES #{mysql_quote(@table)}(id) ON DELETE RESTRICT;
          CREATE TRIGGER #{insert_trigger}
          BEFORE INSERT ON #{payload_table} FOR EACH ROW
          BEGIN
            IF NEW.#{payload_column} IS NULL OR NEW.#{payload_ref_column} IS NULL OR
               NOT (multi_compress_db_dictionary_ref(NEW.#{payload_column}) <=> NEW.#{payload_ref_column}) THEN
              SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'MCDB2 payload dictionary reference must match its dictionary FK';
            END IF;
          END//
          CREATE TRIGGER #{update_trigger}
          BEFORE UPDATE ON #{payload_table} FOR EACH ROW
          BEGIN
            IF NEW.#{payload_column} IS NULL OR NEW.#{payload_ref_column} IS NULL OR
               NOT (multi_compress_db_dictionary_ref(NEW.#{payload_column}) <=> NEW.#{payload_ref_column}) THEN
              SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'MCDB2 payload dictionary reference must match its dictionary FK';
            END IF;
          END//
        SQL
      end

      def identifier!(value, option)
        string = value.to_s
        raise Error, "#{option} must use letters, digits and underscores and cannot start with a digit" unless IDENTIFIER.match?(string)

        string
      end

      def pg_quote(identifier)
        %Q("#{identifier}")
      end

      def pg_qualified(pieces)
        pieces.map { |piece| pg_quote(piece) }.join(".")
      end

      def mysql_quote(identifier)
        "`#{identifier}`"
      end

      def mysql_qualified(pieces)
        pieces.map { |piece| mysql_quote(piece) }.join(".")
      end
    end

    class DeploymentBundle
      DEFAULT_ARCHIVE_EPOCH = 315_619_200

      class DeterministicTarWriter < Gem::Package::TarWriter
        def self.new(io, epoch)
          writer = allocate
          writer.send(:initialize, io, epoch)
          return writer unless block_given?

          begin
            yield writer
          ensure
            writer.close
          end

          nil
        end

        def initialize(io, epoch)
          @archive_epoch = epoch
          super(io)
        end

        def add_file_simple(name, mode, size)
          check_closed

          name, prefix = split_name(name)
          header = Gem::Package::TarHeader.new(
            name: name,
            mode: mode,
            size: size,
            prefix: prefix,
            mtime: @archive_epoch
          ).to_s
          @io.write(header)
          output = BoundedStream.new(@io, size)
          yield output if block_given?
          @io.write("\0" * (size - output.written))
          @io.write("\0" * ((512 - (size % 512)) % 512))
          self
        end

        def mkdir(name, mode)
          check_closed

          name, prefix = split_name(name)
          header = Gem::Package::TarHeader.new(
            name: name,
            mode: mode,
            typeflag: "5",
            size: 0,
            prefix: prefix,
            mtime: @archive_epoch
          )
          @io.write(header)
          self
        end
      end

      TARGETS = {
        "postgres" => {
          source_paths: %w[
            db_core
            postgres_extension
            ext/multi_compress/vendor/zstd
            docs/database-envelope-v1.md
            docs/database-envelope-v2.md
            docs/rfcs/0002-mcdb2-dictionaries.md
            LICENSE.txt
            THIRD_PARTY_NOTICES.md
          ],
          template_path: "db_deployment/postgres"
        },
        "mysql" => {
          source_paths: %w[
            db_core
            mysql_udf
            ext/multi_compress/vendor/zstd
            docs/database-envelope-v1.md
            docs/database-envelope-v2.md
            docs/rfcs/0002-mcdb2-dictionaries.md
            LICENSE.txt
            THIRD_PARTY_NOTICES.md
          ],
          template_path: "db_deployment/mysql"
        }
      }.freeze

      def initialize(target, output, force:)
        @target = target
        @output = File.expand_path(output)
        @force = force
        @root_name = "multi_compress-#{target}-#{MultiCompress::VERSION}"
      end

      def write!
        raise Error, "deployment sources are unavailable from #{ROOT}" unless File.directory?(ROOT)
        raise Error, "#{@output} already exists (use --force to overwrite)" if File.exist?(@output) && !@force

        Dir.mktmpdir("multi-compress-db-package") do |temporary_directory|
          bundle_root = File.join(temporary_directory, @root_name)
          FileUtils.mkdir_p(bundle_root)
          stage_payload!(bundle_root)
          write_metadata!(bundle_root)
          write_tarball!(temporary_directory)
        end
      end

      private

      def stage_payload!(bundle_root)
        target = TARGETS.fetch(@target)
        target.fetch(:source_paths).each do |relative|
          copy_path!(relative, bundle_root)
        end

        template_root = File.join(ROOT, target.fetch(:template_path))
        Dir.children(template_root).sort.each do |entry|
          next if ignored?(entry)

          copy_path!(File.join(target.fetch(:template_path), entry), bundle_root, destination: entry)
        end
      end

      def copy_path!(relative, bundle_root, destination: relative)
        source = File.join(ROOT, relative)
        raise Error, "package source is missing: #{relative}" unless File.exist?(source)

        destination_path = File.join(bundle_root, destination)
        if File.directory?(source)
          FileUtils.mkdir_p(destination_path)
          Dir.children(source).sort.each do |entry|
            next if ignored?(entry)

            copy_path!(File.join(relative, entry), bundle_root, destination: File.join(destination, entry))
          end
        else
          FileUtils.mkdir_p(File.dirname(destination_path))
          FileUtils.copy_file(source, destination_path)
          File.chmod(File.stat(source).mode & 0o777, destination_path)
        end
      end

      def ignored?(entry)
        entry == ".DS_Store" || entry == ".git" || entry == "build" || entry == "test"
      end

      def write_metadata!(bundle_root)
        payload = regular_files(bundle_root).reject do |path|
          %w[manifest.json SHA256SUMS].include?(File.basename(path))
        end
        files = payload.sort.map do |path|
          relative = relative_to(bundle_root, path)
          { "path" => relative, "sha256" => Digest::SHA256.file(path).hexdigest }
        end

        manifest = {
          "bundle_format_version" => BUNDLE_FORMAT_VERSION,
          "gem" => { "name" => "multi_compress", "version" => MultiCompress::VERSION },
          "database_target" => @target,
          "database_envelope" => FORMAT,
          "files" => files
        }
        File.write(File.join(bundle_root, "manifest.json"), JSON.pretty_generate(manifest) + "\n")

        checksum_paths = regular_files(bundle_root).reject { |path| File.basename(path) == "SHA256SUMS" }
        checksums = checksum_paths.sort.map do |path|
          "#{Digest::SHA256.file(path).hexdigest}  #{relative_to(bundle_root, path)}"
        end
        File.write(File.join(bundle_root, "SHA256SUMS"), checksums.join("\n") + "\n")
      end

      def write_tarball!(temporary_directory)
        FileUtils.mkdir_p(File.dirname(@output))
        temporary_output = File.join(
          File.dirname(@output),
          ".#{File.basename(@output)}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp"
        )

        File.open(temporary_output, "wb", 0o644) do |file|
          Zlib::GzipWriter.wrap(file) do |gzip|
            gzip.mtime = archive_epoch
            DeterministicTarWriter.new(gzip, archive_epoch) do |tar|
              add_tree_to_tar!(tar, File.join(temporary_directory, @root_name), @root_name)
            end
          end
        end
        File.rename(temporary_output, @output)
      ensure
        File.delete(temporary_output) if defined?(temporary_output) && File.exist?(temporary_output)
      end

      def archive_epoch
        value = ENV["SOURCE_DATE_EPOCH"]
        return DEFAULT_ARCHIVE_EPOCH unless value&.match?(/\A\d+\z/)

        value.to_i
      end

      def add_tree_to_tar!(tar, directory, archive_path)
        tar.mkdir(archive_path, File.stat(directory).mode & 0o777)
        Dir.children(directory).sort.each do |entry|
          source = File.join(directory, entry)
          destination = File.join(archive_path, entry)
          if File.directory?(source)
            add_tree_to_tar!(tar, source, destination)
          else
            mode = File.stat(source).mode & 0o777
            tar.add_file_simple(destination, mode, File.size(source)) do |destination_io|
              File.open(source, "rb") { |source_io| IO.copy_stream(source_io, destination_io) }
            end
          end
        end
      end

      def regular_files(root)
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      end

      def relative_to(root, path)
        Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      end
    end
  end
end
