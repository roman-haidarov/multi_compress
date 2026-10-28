# frozen_string_literal: true

require "multi_compress"

module MultiCompress
  class Codec
    MAGIC       = "\x89MCDB".b # reserved 5-byte namespace; 0x89 is an
    # invalid UTF-8 lead byte, so it won't
    # collide with valid text. For BINARY data
    # this prefix is reserved, not collision-free.
    VERSION     = 1
    HEADER_SIZE = MAGIC.bytesize + 2 # magic + version byte + algo byte
    B64_PREFIX  = "mc1:"
    MAX_NATIVE_OUTPUT = (2**((0.size * 8) - 1)) - 1

    ALGO_ID  = { zstd: 1, lz4: 2, brotli: 3 }.freeze
    ID_ALGO  = ALGO_ID.invert.freeze

    Options = Struct.new(
      :algo, :level, :encode, :serializer, :encoding, :max_output_size, :legacy, :dictionary,
      keyword_init: true
    )

    DEFAULT_OPTIONS = {
      algo: :zstd, level: nil, encode: nil, serializer: nil, encoding: Encoding::UTF_8,
      max_output_size: nil, legacy: :reject, dictionary: nil
    }.freeze

    private_constant :DEFAULT_OPTIONS, :Options

    def initialize(**values)
      resolved_options = DEFAULT_OPTIONS.merge(values)
      @options = Options.new(**resolved_options)
      validate_options!
    end

    def algo
      @options.algo
    end

    def level
      @options.level
    end

    def max_output_size
      @options.max_output_size
    end

    private

    def validate_options!
      validate_algorithm!
      validate_encoding!
      @options.max_output_size = normalized_output_limit
      @options.legacy = normalize_legacy(@options.legacy)
    end

    def validate_algorithm!
      raise ArgumentError, "unknown algo #{algo.inspect}" unless ALGO_ID.key?(algo)
    end

    def validate_encoding!
      return if [nil, :base64].include?(@options.encode)

      raise ArgumentError, "encode must be nil or :base64"
    end

    def normalized_output_limit
      limit = Integer(@options.max_output_size || MultiCompress.config.max_output_size)
      raise ArgumentError, "max_output_size must be greater than 0" unless limit.positive?
      if limit > MAX_NATIVE_OUTPUT
        raise ArgumentError, "max_output_size must be at most #{MAX_NATIVE_OUTPUT} bytes on this platform"
      end

      limit
    end

    public

    def dump(value)
      return nil if value.nil?

      payload = serialize_payload(value)
      body    = MultiCompress.compress(payload, algo: @options.algo, level: @options.level,
                                                dictionary: @options.dictionary)
      framed  = header + body

      @options.encode == :base64 ? B64_PREFIX + [framed].pack("m0") : framed
    end

    def load(stored)
      return nil if stored.nil?

      framed = decode_transport(stored)
      return decode_payload(unwrap(framed)) if framed

      read_legacy(stored)
    end

    module Envelope
      private

      def header
        (MAGIC + [VERSION, ALGO_ID.fetch(@options.algo)].pack("C2")).b
      end

      def decode_transport(stored)
        if @options.encode == :base64
          s = stored.to_s
          return nil unless s.start_with?(B64_PREFIX)

          decoded = optional_base64(s.byteslice(B64_PREFIX.bytesize, s.bytesize - B64_PREFIX.bytesize))
          decoded&.start_with?(MAGIC) ? decoded : nil
        else
          b = stored.b
          b.start_with?(MAGIC) ? b : nil
        end
      end

      def unwrap(framed)
        raise MultiCompress::DataError, "MultiCompress::Codec: truncated envelope" if framed.bytesize < HEADER_SIZE

        validate_envelope_version!(framed)
        algo = envelope_algorithm(framed)
        body = envelope_body(framed)
        MultiCompress.decompress(body, algo: algo, dictionary: @options.dictionary,
                                       max_output_size: @options.max_output_size)
      end

      def validate_envelope_version!(framed)
        version = framed.getbyte(MAGIC.bytesize)
        return if version == VERSION

        raise MultiCompress::DataError, "MultiCompress::Codec: unsupported envelope version #{version}"
      end

      def envelope_algorithm(framed)
        algo_id = framed.getbyte(MAGIC.bytesize + 1)
        ID_ALGO.fetch(algo_id) do
          raise MultiCompress::DataError, "MultiCompress::Codec: unknown algorithm id #{algo_id}"
        end
      end

      def envelope_body(framed)
        framed.byteslice(HEADER_SIZE, framed.bytesize - HEADER_SIZE) || +"".b
      end

      def read_legacy(stored)
        case @options.legacy[:mode]
        when :reject
          raise MultiCompress::DataError,
                "MultiCompress::Codec: value has no envelope and legacy: :reject is set"
        when :plain
          decode_payload(stored.b.dup)
        when :compressed
          decode_legacy_compressed(stored)
        end
      end

      def decode_legacy_compressed(stored)
        payload = MultiCompress.decompress(
          stored.b,
          algo: @options.legacy[:algo],
          dictionary: @options.dictionary,
          max_output_size: @options.max_output_size
        )
        decode_payload(payload)
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
    end

    module Payload
      private

      def serialize_payload(value)
        if @options.serializer
          @options.serializer.dump(value).b
        else
          serialize_string(value)
        end
      end

      def serialize_string(value)
        unless value.is_a?(String)
          raise TypeError, "MultiCompress::Codec expects a String (or pass serializer:); got #{value.class}"
        end
        if @options.encoding == Encoding::BINARY || value.dup.force_encoding(@options.encoding).valid_encoding?
          return value.b
        end

        raise ArgumentError, "MultiCompress::Codec: value is not valid #{@options.encoding} " \
                             "(use encoding: Encoding::BINARY for arbitrary bytes)"
      end

      def decode_payload(bytes)
        return @options.serializer.load(bytes) if @options.serializer

        finalize_string(bytes)
      end

      def finalize_string(bytes)
        s = bytes.dup.force_encoding(@options.encoding)
        unless @options.encoding == Encoding::BINARY || s.valid_encoding?
          raise MultiCompress::DataError, "MultiCompress::Codec: decoded bytes are not valid #{@options.encoding}"
        end

        s
      end

      def optional_base64(str)
        str.unpack1("m0")&.b
      rescue ArgumentError
        nil
      end
    end

    private_constant :Envelope, :Payload
    include Envelope
    include Payload
  end
end
