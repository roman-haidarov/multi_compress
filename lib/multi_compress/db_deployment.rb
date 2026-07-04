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
    FORMAT = "MCDB1"
    BUNDLE_FORMAT_VERSION = 1

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
          decoded text instead of the compressed bytea/BLOB column.
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

        options = { columns: [], as: "payload", output: nil, extension_schema: "multi_compress" }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: multi_compress db view #{target} --table SCHEMA.TABLE --column COLUMN --view SCHEMA.VIEW --columns ID,CREATED_AT [OPTIONS]"
          opts.on("--table NAME", "source table, optionally schema-qualified") { |value| options[:table] = value }
          opts.on("--column NAME", "compressed bytea/BLOB column") { |value| options[:column] = value }
          opts.on("--view NAME", "destination view, optionally schema-qualified") { |value| options[:view] = value }
          opts.on("--columns LIST", "comma-separated plain columns to expose") { |value| options[:columns] = value.split(",").map(&:strip) }
          opts.on("--as NAME", "decoded column name (default: payload)") { |value| options[:as] = value }
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
        selections << "  #{pg_quote(@extension_schema)}.multi_compress_db_decompress(source.#{pg_quote(@column)}) AS #{pg_quote(@decoded_name)}"

        <<~SQL
          -- Generated by multi_compress #{MultiCompress::VERSION}. Keep this view in your schema migrations.
          -- Query it in DBeaver; do not expose the compressed column for ad-hoc reading.
          CREATE OR REPLACE VIEW #{pg_qualified(@view)} AS
          SELECT
          #{selections.join(",\n")}
          FROM #{pg_qualified(@table)} AS source;
        SQL
      end

      def mysql_sql
        selections = @columns.map { |column| "  source.#{mysql_quote(column)}" }
        selections << "  CONVERT(multi_compress_db_decompress(source.#{mysql_quote(@column)}) USING utf8mb4) AS #{mysql_quote(@decoded_name)}"

        <<~SQL
          -- Generated by multi_compress #{MultiCompress::VERSION}. Keep this view in your schema migrations.
          -- Query it in DBeaver; do not expose the compressed column for ad-hoc reading.
          CREATE OR REPLACE VIEW #{mysql_qualified(@view)} AS
          SELECT
          #{selections.join(",\n")}
          FROM #{mysql_qualified(@table)} AS source;
        SQL
      end

      def qualified_identifier!(value, option)
        pieces = value.to_s.split(".", -1)
        unless pieces.length.between?(1, 2) && pieces.all? { |piece| IDENTIFIER.match?(piece) }
          raise Error, "#{option} must be NAME or SCHEMA.NAME using letters, digits and underscores"
        end
        pieces
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
