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

  DEFAULT_MAX_OUTPUT_SIZE = 512 * 1024 * 1024
  DEFAULT_STREAMING_MAX_OUTPUT_SIZE = 2 * 1024 * 1024 * 1024

  EXTENSION_MAP = {
    ".zst"  => :zstd,
    ".zstd" => :zstd,
    ".lz4"  => :lz4,
    ".br"   => :brotli,
  }.freeze

  private_constant :EXTENSION_MAP

  class Config
    attr_reader :max_output_size, :streaming_max_output_size

    def initialize
      reset!
    end

    def max_output_size=(value)
      @max_output_size = normalize_limit(value, :max_output_size, DEFAULT_MAX_OUTPUT_SIZE)
    end

    def streaming_max_output_size=(value)
      @streaming_max_output_size = normalize_limit(
        value,
        :streaming_max_output_size,
        DEFAULT_STREAMING_MAX_OUTPUT_SIZE
      )
    end

    def reset!
      @max_output_size = DEFAULT_MAX_OUTPUT_SIZE
      @streaming_max_output_size = DEFAULT_STREAMING_MAX_OUTPUT_SIZE
      self
    end

    def dup
      copy = self.class.new
      copy.max_output_size = max_output_size
      copy.streaming_max_output_size = streaming_max_output_size
      copy
    end

    private

    def normalize_limit(value, name, default)
      return default if value.nil?
      raise TypeError, "#{name} must be an Integer" unless value.respond_to?(:to_int)

      limit = value.to_int
      raise ArgumentError, "#{name} must be greater than 0" if limit <= 0

      limit
    end
  end

  class << self
    def config
      @config ||= Config.new
    end

    def configure
      return config unless block_given?

      yield(config)
      config
    end

    unless private_method_defined?(:_c_decompress)
      alias_method :_c_decompress, :decompress
      private :_c_decompress
    end
  end

  def self.zstd(data, level: nil)
    compress(data, algo: :zstd, level: level)
  end

  def self.lz4(data, level: nil, format: nil)
    if format
      compress(data, algo: :lz4, level: level, format: format)
    else
      compress(data, algo: :lz4, level: level)
    end
  end

  def self.brotli(data, level: nil)
    compress(data, algo: :brotli, level: level)
  end

  def self.decompress(data, **opts)
    _c_decompress(data, **resolved_one_shot_options(opts))
  end

  def self.zstd_decompress(data)
    decompress(data, algo: :zstd)
  end

  def self.lz4_decompress(data, format: nil)
    if format
      decompress(data, algo: :lz4, format: format)
    else
      decompress(data, algo: :lz4)
    end
  end

  def self.brotli_decompress(data)
    decompress(data, algo: :brotli)
  end

  def self.algo_from_ext(path)
    EXTENSION_MAP[File.extname(path).downcase]
  end

  def self.resolved_one_shot_options(opts)
    return opts.merge(max_output_size: config.max_output_size) unless opts.key?(:max_output_size)

    opts
  end

  private_class_method :resolved_one_shot_options

  module InflaterDefaults
    def initialize(*args, **opts)
      resolved = opts.dup
      resolved[:max_output_size] = MultiCompress.config.streaming_max_output_size unless resolved.key?(:max_output_size)
      super(*args, **resolved)
    end
  end

  Inflater.prepend(InflaterDefaults)

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
      args.flatten.each do |arg|
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

  class Reader
    CHUNK_SIZE = 8192
    BUFFER_COMPACT_THRESHOLD = 64 * 1024

    def self.open(path_or_io, algo: nil, dictionary: nil, **opts, &block)
      io, algo, owned = resolve_io(path_or_io, algo, mode: "rb")
      reader = new(io, algo: algo, dictionary: dictionary, **opts)
      reader.instance_variable_set(:@owned_io, owned)

      return reader unless block

      begin
        yield reader
      ensure
        reader.close
      end
    end

    def initialize(io, algo: nil, dictionary: nil, **opts)
      @io          = io
      @inflater    = Inflater.new(algo: algo, dictionary: dictionary, **opts)
      @closed      = false
      @owned_io    = false
      @buffer      = +"".b
      @buffer_pos  = 0
      @eof         = false
    end

    def read(length = nil)
      ensure_open!
      return read_all if length.nil?

      read_exactly(length)
    end

    def gets(separator = "\n")
      ensure_open!
      return nil if @eof && buffer_empty?

      fill_buffer_until { buffer_includes?(separator) }

      return extract_line(separator) if buffer_includes?(separator)
      return consume_buffer unless buffer_empty?

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
      @eof && buffer_empty?
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
      end
    end

    def readline
      gets || raise(EOFError, "end of file reached")
    end

    private

    def ensure_open!
      raise StreamError, "reader is closed" if @closed
    end

    def buffer_size
      @buffer.bytesize - @buffer_pos
    end

    def buffer_empty?
      @buffer_pos >= @buffer.bytesize
    end

    def buffer_append(data)
      compact_buffer_if_needed
      @buffer << data
    end

    def compact_buffer_if_needed
      return if @buffer_pos == 0

      total = @buffer.bytesize
      return unless @buffer_pos >= BUFFER_COMPACT_THRESHOLD && @buffer_pos * 2 >= total

      @buffer = @buffer.byteslice(@buffer_pos, total - @buffer_pos)
      @buffer_pos = 0
    end

    def buffer_includes?(separator)
      idx = @buffer.index(separator, @buffer_pos)
      !idx.nil?
    end

    def read_all
      return nil if @eof && buffer_empty?

      result = if buffer_empty?
        +"".b
      else
        @buffer.byteslice(@buffer_pos, @buffer.bytesize - @buffer_pos) || +"".b
      end
      @buffer.clear
      @buffer_pos = 0

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
      return nil if @eof && buffer_empty?

      fill_buffer_until { buffer_size >= length }

      if buffer_size >= length
        result = @buffer.byteslice(@buffer_pos, length)
        @buffer_pos += length
        compact_buffer_if_needed
        result
      elsif !buffer_empty?
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
        buffer_append(decompressed) if decompressed
      end
    end

    def extract_line(separator)
      idx = @buffer.index(separator, @buffer_pos)
      end_pos = idx + separator.bytesize
      result = @buffer.byteslice(@buffer_pos, end_pos - @buffer_pos)
      @buffer_pos = end_pos
      compact_buffer_if_needed
      result
    end

    def consume_buffer
      result = @buffer.byteslice(@buffer_pos, @buffer.bytesize - @buffer_pos) || +"".b
      @buffer.clear
      @buffer_pos = 0
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
