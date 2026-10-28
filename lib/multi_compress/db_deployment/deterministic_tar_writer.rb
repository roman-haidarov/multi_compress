# frozen_string_literal: true

module MultiCompress
  module DBDeployment
    class DeterministicTarWriter < Gem::Package::TarWriter
      attr_reader :archive_epoch
      private :archive_epoch

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
        write_file_header(name, prefix, mode, size)
        write_file_body(size) { |output| yield output if block_given? }
        self
      end

      def mkdir(name, mode)
        check_closed
        name, prefix = split_name(name)
        @io.write(directory_header(name, prefix, mode))
        self
      end

      private

      def write_file_header(name, prefix, mode, size)
        header = Gem::Package::TarHeader.new(
          name: name,
          mode: mode,
          size: size,
          prefix: prefix,
          mtime: archive_epoch
        ).to_s
        @io.write(header)
      end

      def write_file_body(size)
        output = BoundedStream.new(@io, size)
        yield output
        @io.write("\0" * (size - output.written))
        padding = (512 - (size % 512)) % 512
        @io.write("\0" * padding)
      end

      def directory_header(name, prefix, mode)
        Gem::Package::TarHeader.new(
          name: name,
          mode: mode,
          typeflag: "5",
          size: 0,
          prefix: prefix,
          mtime: archive_epoch
        )
      end
    end
  end
end
