# frozen_string_literal: true

module MultiCompress
  class Writer
    CHUNK_BUFFER_SIZE = 8192

    def self.open(path_or_io, algo: nil, level: nil, dictionary: nil, &block)
      io, algo, owned = StreamIO.resolve_io(path_or_io, algo, mode: "wb")
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
  end
end
