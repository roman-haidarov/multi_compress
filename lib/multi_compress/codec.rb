# frozen_string_literal: true

require "multi_compress"

module MultiCompress
  class Codec
    MAGIC       = "\x89MCDB".b       # reserved 5-byte namespace; 0x89 is an
                                     # invalid UTF-8 lead byte, so it won't
                                     # collide with valid text. For BINARY data
                                     # this prefix is reserved, not collision-free.
    VERSION     = 1
    HEADER_SIZE = MAGIC.bytesize + 2 # magic + version byte + algo byte
    B64_PREFIX  = "mc1:"
    MAX_NATIVE_OUTPUT = (2**(0.size * 8 - 1)) - 1

    ALGO_ID  = { zstd: 1, lz4: 2, brotli: 3 }.freeze
    ID_ALGO  = ALGO_ID.invert.freeze

    attr_reader :algo, :level, :max_output_size

    def initialize(algo: :zstd, level: nil, encode: nil, serializer: nil,
                   encoding: Encoding::UTF_8, max_output_size: nil,
                   legacy: :reject, dictionary: nil)
      raise ArgumentError, "unknown algo #{algo.inspect}" unless ALGO_ID.key?(algo)
      raise ArgumentError, "encode must be nil or :base64" unless [nil, :base64].include?(encode)

      @algo            = algo
      @level           = level
      @encode          = encode
      @serializer      = serializer
      @encoding        = encoding
      limit            = Integer(max_output_size || MultiCompress.config.max_output_size)
      raise ArgumentError, "max_output_size must be greater than 0" unless limit.positive?
      if limit > MAX_NATIVE_OUTPUT
        raise ArgumentError,
              "max_output_size must be at most #{MAX_NATIVE_OUTPUT} bytes on this platform"
      end

      @max_output_size = limit
      @legacy          = normalize_legacy(legacy)
      @dictionary      = dictionary
    end

    def dump(value)
      return nil if value.nil?

      payload = serialize_payload(value)
      body    = MultiCompress.compress(payload, algo: @algo, level: @level, dictionary: @dictionary)
      framed  = header + body

      @encode == :base64 ? B64_PREFIX + [framed].pack("m0") : framed
    end

    def load(stored)
      return nil if stored.nil?

      framed = decode_transport(stored)
      return decode_payload(unwrap(framed)) if framed

      read_legacy(stored)
    end

    private

    def header
      (MAGIC + [VERSION, ALGO_ID.fetch(@algo)].pack("C2")).b
    end

    def decode_transport(stored)
      if @encode == :base64
        s = stored.to_s
        return nil unless s.start_with?(B64_PREFIX)

        decoded = optional_base64(s.byteslice(B64_PREFIX.bytesize, s.bytesize - B64_PREFIX.bytesize))
        decoded && decoded.start_with?(MAGIC) ? decoded : nil
      else
        b = stored.b
        b.start_with?(MAGIC) ? b : nil
      end
    end

    def unwrap(framed)
      if framed.bytesize < HEADER_SIZE
        raise MultiCompress::DataError, "MultiCompress::Codec: truncated envelope"
      end

      version = framed.getbyte(MAGIC.bytesize)
      algo_id = framed.getbyte(MAGIC.bytesize + 1)
      unless version == VERSION
        raise MultiCompress::DataError, "MultiCompress::Codec: unsupported envelope version #{version}"
      end
      algo = ID_ALGO[algo_id]
      raise MultiCompress::DataError, "MultiCompress::Codec: unknown algorithm id #{algo_id}" unless algo

      body = framed.byteslice(HEADER_SIZE, framed.bytesize - HEADER_SIZE) || +"".b
      MultiCompress.decompress(body, algo: algo, dictionary: @dictionary, max_output_size: @max_output_size)
    end

    def read_legacy(stored)
      case @legacy[:mode]
      when :reject
        raise MultiCompress::DataError,
              "MultiCompress::Codec: value has no envelope and legacy: :reject is set"
      when :plain
        decode_payload(stored.b.dup)
      when :compressed
        payload = MultiCompress.decompress(
          stored.b, algo: @legacy[:algo], dictionary: @dictionary, max_output_size: @max_output_size
        )
        decode_payload(payload)
      end
    end

    def normalize_legacy(legacy)
      case legacy
      when :reject, :plain
        { mode: legacy }
      when Hash
        algo = legacy[:compressed]
        raise ArgumentError, "legacy: { compressed: <algo> } required" unless ALGO_ID.key?(algo)

        { mode: :compressed, algo: algo }
      else
        raise ArgumentError, "legacy: must be :reject, :plain, or { compressed: :algo }"
      end
    end

    def serialize_payload(value)
      if @serializer
        @serializer.dump(value).b
      else
        unless value.is_a?(String)
          raise TypeError, "MultiCompress::Codec expects a String (or pass serializer:); got #{value.class}"
        end

        unless @encoding == Encoding::BINARY || value.dup.force_encoding(@encoding).valid_encoding?
          raise ArgumentError, "MultiCompress::Codec: value is not valid #{@encoding} " \
                               "(use encoding: Encoding::BINARY for arbitrary bytes)"
        end
        value.b
      end
    end

    def decode_payload(bytes)
      return @serializer.load(bytes) if @serializer

      finalize_string(bytes)
    end

    def finalize_string(bytes)
      s = bytes.dup.force_encoding(@encoding)
      unless @encoding == Encoding::BINARY || s.valid_encoding?
        raise MultiCompress::DataError, "MultiCompress::Codec: decoded bytes are not valid #{@encoding}"
      end
      s
    end

    def optional_base64(str)
      str.unpack1("m0")&.b
    rescue ArgumentError
      nil
    end
  end
end
