# frozen_string_literal: true

module MultiCompress
  module DBDeployment
    module CommandHelpers
      private

      def validated_target!(argv, targets)
        target = argv.shift
        raise OptionParser::MissingArgument, "TARGET must be postgres or mysql" if target.nil?
        raise OptionParser::InvalidArgument, "TARGET must be postgres or mysql" unless targets.include?(target)

        target
      end

      def show_help(parser)
        puts parser
        0
      end

      def write_sql(sql, output)
        if output
          write_text_atomically(output, sql)
          puts File.expand_path(output)
        else
          $stdout.write(sql)
        end
      end

      def write_text_atomically(path, contents)
        directory = File.dirname(File.expand_path(path))
        FileUtils.mkdir_p(directory)
        temporary = File.join(directory, ".multi-compress-view-#{Process.pid}-#{SecureRandom.hex(8)}")
        File.open(temporary, "wb", 0o644) { |file| file.write(contents) }
        File.rename(temporary, path)
      ensure
        File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
      end

      def add_value_options(parser, options, definitions)
        definitions.each do |key, flag, description|
          parser.on("--#{flag} NAME", description) { |value| options[key] = value }
        end
      end
    end

    class CLI
      COMMANDS = {
        "package" => "PackageCommand",
        "view" => "ViewCommand",
        "registry" => "RegistryCommand"
      }.freeze
      HELP_COMMANDS = ["help", "--help", "-h", nil].freeze

      def self.run(argv)
        new.run(argv)
      end

      def run(argv)
        dispatch(argv)
      rescue OptionParser::ParseError, Error => e
        report_error(e, 2)
      rescue SystemCallError, IOError => e
        report_error(e, 1)
      end

      private

      def dispatch(argv)
        command = argv.shift
        return show_help if HELP_COMMANDS.include?(command)

        command_class = DBDeployment.const_get(
          COMMANDS.fetch(command) { raise OptionParser::InvalidOption, "unknown db command: #{command.inspect}" },
          false
        )
        command_class.new.run(argv)
      end

      def report_error(error, status)
        warn "multi_compress db: #{error.message}"
        status
      end

      def show_help
        puts help
        0
      end

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
      include CommandHelpers

      TARGETS = %w[postgres mysql].freeze

      def run(argv)
        target = validated_target!(argv, TARGETS)
        options = { output: nil, force: false }
        parser = option_parser(target, options)
        parser.parse!(argv)
        return show_help(options[:help]) if options[:help]

        raise OptionParser::InvalidOption, argv.join(" ") unless argv.empty?

        write_bundle(target, options)
        0
      end

      private

      def option_parser(target, options)
        OptionParser.new do |parser|
          parser.banner = "Usage: multi_compress db package #{target} [OPTIONS]"
          parser.on("-o", "--output PATH", "write the deployment archive to PATH") do |value|
            options[:output] = value
          end
          parser.on("-f", "--force", "overwrite an existing archive") { options[:force] = true }
          parser.on("-h", "--help", "show this help") { options[:help] = parser }
        end
      end

      def write_bundle(target, options)
        output = options[:output] || "multi_compress-#{target}-#{MultiCompress::VERSION}.tar.gz"
        DeploymentBundle.new(target, output, force: options[:force]).write!
        puts File.expand_path(output)
      end
    end

    class SqlCommand
      include CommandHelpers

      def run(argv)
        target = validated_target!(argv, self.class::TARGETS)
        options = default_options
        parser = option_parser(target, options)
        parser.parse!(argv)
        return show_help(options[:help]) if options[:help]

        raise OptionParser::InvalidOption, argv.join(" ") unless argv.empty?

        write_sql(build_sql(target, options), options[:output])
        0
      end

      private

      def build_sql(_target, _options)
        raise NotImplementedError
      end
    end

    class ViewCommand < SqlCommand
      TARGETS = %w[postgres mysql].freeze
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze
      DICTIONARY_OPTION_DEFINITIONS = [
        [:dictionary_table, "dictionary-table", "MCDB2 immutable dictionary registry table"],
        [:dictionary_id_column, "dictionary-id-column", "MCDB2 FK column on source table"],
        [:registry_id_column, "registry-id-column", "registry PK (default: id)"],
        [:dictionary_sha256_column, "dictionary-sha256-column", "registry SHA-256 column (default: sha256)"],
        [:dictionary_bytes_column, "dictionary-bytes-column", "registry dictionary bytes column (default: bytes)"]
      ].map(&:freeze).freeze

      private_constant :DICTIONARY_OPTION_DEFINITIONS

      private

      def build_sql(target, options)
        ReadableView.new(target, options).to_sql
      end

      def default_options
        {
          columns: [], as: "payload", output: nil, extension_schema: "multi_compress",
          dictionary_table: nil, dictionary_id_column: nil, registry_id_column: "id",
          dictionary_sha256_column: "sha256", dictionary_bytes_column: "bytes"
        }
      end

      def option_parser(target, options)
        OptionParser.new do |parser|
          parser.banner = view_usage(target)
          add_source_options(parser, options)
          add_dictionary_options(parser, options)
          add_view_output_options(parser, target, options)
        end
      end

      def view_usage(target)
        "Usage: multi_compress db view #{target} --table SCHEMA.TABLE --column COLUMN " \
          "--view SCHEMA.VIEW --columns ID,CREATED_AT [OPTIONS]"
      end

      def add_source_options(parser, options)
        parser.on("--table NAME", "source table, optionally schema-qualified") { |value| options[:table] = value }
        parser.on("--column NAME", "compressed bytea/BLOB column") { |value| options[:column] = value }
        parser.on("--view NAME", "destination view, optionally schema-qualified") { |value| options[:view] = value }
        parser.on("--columns LIST", "comma-separated plain columns to expose") do |value|
          options[:columns] = value.split(",").map(&:strip)
        end
        parser.on("--as NAME", "decoded column name (default: payload)") { |value| options[:as] = value }
      end

      def add_dictionary_options(parser, options)
        add_value_options(parser, options, DICTIONARY_OPTION_DEFINITIONS)
      end

      def add_view_output_options(parser, target, options)
        if target == "postgres"
          parser.on("--extension-schema NAME", "extension schema (default: multi_compress)") do |value|
            options[:extension_schema] = value
          end
        end
        parser.on("-o", "--output PATH", "write SQL to PATH instead of stdout") { |value| options[:output] = value }
        parser.on("-h", "--help", "show this help") { options[:help] = parser }
      end
    end

    class RegistryCommand < SqlCommand
      TARGETS = %w[postgres mysql].freeze
      TABLE_OPTION_DEFINITIONS = [
        [:table, "table", "versions table (default: mcdb_dictionary_versions)"],
        [:heads_table, "heads-table", "heads table (default: mcdb_dictionary_heads)"],
        [:payload_table, "payload-table", "MCDB2 source table in this schema/database"],
        [:payload_column, "payload-column", "MCDB2 compressed envelope column on --payload-table"],
        [:payload_dictionary_id_column, "payload-dictionary-id-column",
         "MCDB2 dictionary FK column on --payload-table"]
      ].map(&:freeze).freeze

      private_constant :TABLE_OPTION_DEFINITIONS

      private

      def build_sql(target, options)
        DictionaryRegistry.new(target, options).to_sql
      end

      def default_options
        { output: nil, extension_schema: "multi_compress", table: "mcdb_dictionary_versions",
          heads_table: "mcdb_dictionary_heads" }
      end

      def option_parser(target, options)
        OptionParser.new do |parser|
          parser.banner = "Usage: multi_compress db registry #{target} [OPTIONS]"
          add_target_options(parser, target, options)
          add_registry_table_options(parser, options)
          add_registry_output_options(parser, options)
        end
      end

      def add_target_options(parser, target, options)
        return add_postgres_options(parser, options) if target == "postgres"

        parser.on("--database NAME", "application database") { |value| options[:schema] = value }
      end

      def add_postgres_options(parser, options)
        parser.on("--schema NAME", "application schema") { |value| options[:schema] = value }
        parser.on("--owner ROLE", "NOLOGIN owner for append-only dictionary versions") do |value|
          options[:owner] = value
        end
        parser.on("--migration-role ROLE", "role allowed to insert dictionary versions") do |value|
          options[:migration_role] = value
        end
        parser.on("--extension-schema NAME", "extension schema (default: multi_compress)") do |value|
          options[:extension_schema] = value
        end
      end

      def add_registry_table_options(parser, options)
        add_value_options(parser, options, TABLE_OPTION_DEFINITIONS)
      end

      def add_registry_output_options(parser, options)
        parser.on("-o", "--output PATH", "write SQL to PATH instead of stdout") { |value| options[:output] = value }
        parser.on("-h", "--help", "show this help") { options[:help] = parser }
      end
    end
  end
end
