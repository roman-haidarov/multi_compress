# frozen_string_literal: true

module MultiCompress
  class Reader
    CHUNK_SIZE = 8192
    require "multi_compress/reader/buffer_operations"
    require "multi_compress/reader/read_operations"
    include BufferOperations
    include ReadOperations

    def self.open(path_or_io, algo: nil, dictionary: nil, **opts, &block)
      io, algo, owned = StreamIO.resolve_io(path_or_io, algo, mode: "rb")
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
  end
end
