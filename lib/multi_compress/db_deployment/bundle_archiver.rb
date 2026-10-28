# frozen_string_literal: true

module MultiCompress
  module DBDeployment
    class BundleArchiver
      DEFAULT_EPOCH = 315_619_200
      attr_reader :output, :root_name
      private :output, :root_name

      def initialize(output, root_name)
        @output = output
        @root_name = root_name
      end

      def write!(temporary_directory)
        temporary_output = temporary_path
        FileUtils.mkdir_p(File.dirname(output))
        write_archive(temporary_output, temporary_directory)
        File.rename(temporary_output, output)
      ensure
        File.delete(temporary_output) if defined?(temporary_output) && File.exist?(temporary_output)
      end

      private

      def temporary_path
        File.join(File.dirname(output), ".#{File.basename(output)}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp")
      end

      def write_archive(path, temporary_directory)
        File.open(path, "wb", 0o644) do |file|
          Zlib::GzipWriter.wrap(file) do |gzip|
            gzip.mtime = archive_epoch
            DeterministicTarWriter.new(gzip, archive_epoch) do |tar|
              add_tree(tar, File.join(temporary_directory, root_name), root_name)
            end
          end
        end
      end

      def archive_epoch
        value = ENV.fetch("SOURCE_DATE_EPOCH", nil)
        value&.match?(/\A\d+\z/) ? value.to_i : DEFAULT_EPOCH
      end

      def add_tree(tar, directory, archive_path)
        tar.mkdir(archive_path, mode(directory))
        Dir.children(directory).sort.each { |entry| add_entry(tar, directory, archive_path, entry) }
      end

      def add_entry(tar, directory, archive_path, entry)
        source = File.join(directory, entry)
        destination = File.join(archive_path, entry)
        return add_tree(tar, source, destination) if File.directory?(source)

        add_file(tar, source, destination)
      end

      def add_file(tar, source, destination)
        tar.add_file_simple(destination, mode(source), File.size(source)) do |destination_io|
          File.open(source, "rb") { |source_io| IO.copy_stream(source_io, destination_io) }
        end
      end

      def mode(path)
        File.stat(path).mode & 0o777
      end
    end
  end
end
