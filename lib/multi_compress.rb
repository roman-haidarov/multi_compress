# frozen_string_literal: true

require "multi_compress/version"

begin
  require "multi_compress/multi_compress"
rescue LoadError
  ext_dir = File.expand_path("../multi_compress", __FILE__)

  so_path = %w[.bundle .so]
    .map { |ext| File.join(ext_dir, "multi_compress#{ext}") }
    .find { |path| File.exist?(path) }

  raise LoadError, "Could not find compiled MultiCompress extension. Run: bundle exec rake compile" unless so_path

  require so_path
end

module MultiCompress
  FASTEST = :fastest
  DEFAULT = :default
  BEST    = :best

  EXTENSION_MAP = {
    ".zst"  => :zstd,
    ".zstd" => :zstd,
    ".lz4"  => :lz4,
    ".br"   => :brotli,
  }.freeze

  private_constant :EXTENSION_MAP

  def self.zstd(data, level: nil)
    compress(data, algo: :zstd, **level_opts(level))
  end

  def self.lz4(data, level: nil)
    compress(data, algo: :lz4, **level_opts(level))
  end

  def self.brotli(data, level: nil)
    compress(data, algo: :brotli, **level_opts(level))
  end

  def self.zstd_decompress(data)
    decompress(data, algo: :zstd)
  end

  def self.lz4_decompress(data)
    decompress(data, algo: :lz4)
  end

  def self.brotli_decompress(data)
    decompress(data, algo: :brotli)
  end

  def self.algo_from_ext(path)
    EXTENSION_MAP[File.extname(path).downcase]
  end

  def self.level_opts(level)
    level ? { level: level } : {}
  end

  private_class_method :level_opts

  # Streaming compressed writer.
  #
  # Supports block form via +Writer.open+ or manual lifecycle management.
  class Writer
    CHUNK_BUFFER_SIZE = 8192

    def self.open(path_or_io, algo: nil, level: nil, dictionary: nil, &block)
      io, algo, owned = resolve_io(path_or_io, algo, mode: "wb")
      writer = new(io, algo: algo || :zstd, level: level, dictionary: dictionary)
      writer.instance_variable_set(:@owned_io, owned)

      return writer unless block

      begin
        yield writer
      ensure
        writer.close
      end
    end

    def initialize(io, algo: :zstd, level: nil, dictionary: nil)
      @io       = io
      @deflater = Deflater.new(algo: algo, level: level, dictionary: dictionary)
      @closed   = false
      @owned_io = false
    end

    def write(data)
      ensure_open!
      bytes = data.to_s
      flush_compressed(@deflater.write(bytes))
      bytes.bytesize
    end

    def flush
      ensure_open!
      flush_compressed(@deflater.flush)
      @io.flush if @io.respond_to?(:flush)
      self
    end

    def close
      return if @closed

      flush_compressed(@deflater.finish)
      @deflater.close
      @io.close if @owned_io && @io.respond_to?(:close)
      @closed = true
      nil
    end

    def closed?
      @closed
    end

    def <<(data)
      write(data)
      self
    end

    def puts(*args)
      args.each do |arg|
        str = arg.to_s
        write(str)
        write("\n") unless str.end_with?("\n")
      end
      nil
    end

    def print(*args)
      args.each { |arg| write(arg.to_s) }
      nil
    end

    private

    def ensure_open!
      raise StreamError, "writer is closed" if @closed
    end

    def flush_compressed(compressed)
      @io.write(compressed) if compressed && !compressed.empty?
    end

    def self.resolve_io(path_or_io, algo, mode:)
      if path_or_io.is_a?(String)
        [File.open(path_or_io, mode), algo || MultiCompress.algo_from_ext(path_or_io), true]
      else
        [path_or_io, algo, false]
      end
    end

    private_class_method :resolve_io
  end

  # Streaming compressed reader.
  #
  # Supports block form via +Reader.open+ or manual lifecycle management.
  class Reader
    CHUNK_SIZE = 8192

    def self.open(path_or_io, algo: nil, dictionary: nil, max_output_size: nil, max_ratio: 1000, &block)
      io, algo, owned = resolve_io(path_or_io, algo, mode: "rb")
      reader = new(io, algo: algo, dictionary: dictionary, max_output_size: max_output_size, max_ratio: max_ratio)
      reader.instance_variable_set(:@owned_io, owned)

      return reader unless block

      begin
        yield reader
      ensure
        reader.close
      end
    end

    def initialize(io, algo: nil, dictionary: nil, max_output_size: nil, max_ratio: 1000)
      @io       = io
      @inflater = Inflater.new(algo: algo, dictionary: dictionary, max_output_size: max_output_size, max_ratio: max_ratio)
      @closed   = false
      @owned_io = false
      @buffer   = +""
      @eof      = false
    end

    def read(length = nil)
      ensure_open!
      return read_all if length.nil?

      read_exactly(length)
    end

    def gets(separator = "\n")
      ensure_open!
      return nil if @eof && @buffer.empty?

      fill_buffer_until { @buffer.include?(separator) }

      return extract_line(separator) if @buffer.include?(separator)
      return consume_buffer unless @buffer.empty?

      nil
    end

    def close
      return if @closed

      @inflater.close
      @io.close if @owned_io && @io.respond_to?(:close)
      @closed = true
      nil
    end

    def closed?
      @closed
    end

    def eof?
      @eof && @buffer.empty?
    end

    def each_line
      return enum_for(:each_line) unless block_given?

      while (line = gets)
        yield line
      end
    end

    def each_chunk(size)
      return enum_for(:each_chunk, size) unless block_given?

      while (chunk = read(size))
        yield chunk
        break if chunk.bytesize < size
      end
    end

    def readline
      gets || raise(EOFError, "end of file reached")
    end

    private

    def ensure_open!
      raise StreamError, "reader is closed" if @closed
    end

    def read_all
      return nil if @eof && @buffer.empty?

      result = @buffer.dup
      @buffer.clear

      until @eof
        chunk = read_compressed_chunk
        break unless chunk && !chunk.empty?

        decompressed = @inflater.write(chunk)
        result << decompressed if decompressed
      end

      final = @inflater.finish
      result << final if final && !final.empty?

      result.empty? ? nil : result
    end

    def read_exactly(length)
      return +("") if @eof && @buffer.empty?

      fill_buffer_until { @buffer.bytesize >= length }

      if @buffer.bytesize >= length
        result  = @buffer[0, length]
        @buffer = @buffer[length..]
        result
      elsif !@buffer.empty?
        consume_buffer
      end
    end

    def fill_buffer_until
      until yield || @eof
        chunk = read_compressed_chunk
        if chunk.nil? || chunk.empty?
          @eof = true
          break
        end
        decompressed = @inflater.write(chunk)
        @buffer << decompressed if decompressed
      end
    end

    def extract_line(separator)
      idx    = @buffer.index(separator)
      result = @buffer[0..idx]
      @buffer = @buffer[(idx + 1)..]
      result
    end

    def consume_buffer
      result  = @buffer
      @buffer = +""
      result
    end

    def read_compressed_chunk
      @io.read(CHUNK_SIZE)
    rescue EOFError
      nil
    end

    def self.resolve_io(path_or_io, algo, mode:)
      if path_or_io.is_a?(String)
        [File.open(path_or_io, mode), algo || MultiCompress.algo_from_ext(path_or_io), true]
      else
        [path_or_io, algo, false]
      end
    end

    private_class_method :resolve_io
  end
end
