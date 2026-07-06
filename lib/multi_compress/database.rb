# frozen_string_literal: true

require "digest"
require "multi_compress"

module MultiCompress
  # Long-term, SQL-readable envelopes. MCDB1 is dictionary-free. MCDB2 is an
  # opt-in, dictionary-required format for one homogeneous database column.
  module Database
    MAGIC        = "MCDB".b
    VERSION_V1   = 1
    VERSION_V2   = 2
    VERSION      = VERSION_V1 # MCDB1 compatibility alias
    CODEC_ZSTD   = 1
    FLAGS_NONE   = 0
    FLAGS_V1     = FLAGS_NONE
    V1_HEADER_SIZE = 19 # 4 magic + 1 version + 1 codec + 1 flags + 8 size + 4 crc32
    V2_HEADER_SIZE = 27 # MCDB1 header + 8 byte application dictionary_ref
    HEADER_SIZE    = V1_HEADER_SIZE
    ORIGINAL_SIZE_OFFSET = 7
    CRC_OFFSET           = 15
    DICTIONARY_REF_OFFSET = 19
    MAX_OUTPUT   = 16 * 1024 * 1024
    MAX_DICTIONARY_BYTES = 256 * 1024
    MAX_DICTIONARY_REF = (2**63) - 1
    MAX_ENVELOPE_V1 = 16_842_771
    MAX_ENVELOPE_V2 = 16_842_779
    MAX_ENVELOPE = MAX_ENVELOPE_V2
    ZSTD_LEVEL   = 6

    # A strict, immutable MCDB2 dictionary. It is intentionally distinct from
    # MultiCompress::Dictionary: MCDB2 accepts only conformant zstd dictionaries
    # with a non-zero zstd DictID and an application-level registry id.
    class Dictionary
      attr_reader :id, :bytes, :sha256, :zstd_id, :native

      def self.train(samples, id:, size: 32 * 1024)
        new(id: id, native: MultiCompress::Zstd.train_dictionary(samples, size: size))
      end

      def self.wrap(native, id:)
        new(id: id, native: native)
      end

      def initialize(id:, native: nil, bytes: nil)
        @id = normalize_id(id)
        raise ArgumentError, "provide exactly one of native: or bytes:" if (!!native) == (!!bytes)

        @native = native || MultiCompress::Dictionary.new(bytes, algo: :zstd)
        unless @native.is_a?(MultiCompress::Dictionary) && @native.algo == :zstd
          raise TypeError, "MCDB2 dictionary must be a MultiCompress::Dictionary with algo: :zstd"
        end

        @bytes = @native.bytes.b.freeze
        if @bytes.empty? || @bytes.bytesize > MAX_DICTIONARY_BYTES
          raise ArgumentError,
                "MCDB2 dictionary is #{@bytes.bytesize} bytes; allowed range is 1..#{MAX_DICTIONARY_BYTES}"
        end

        @zstd_id = @native.zstd_id
        raise ArgumentError, "MCDB2 dictionary must be a conformant zstd dictionary with a non-zero DictID" if @zstd_id.zero?

        @sha256 = Digest::SHA256.digest(@bytes).freeze
        freeze
      end

      def sha256_hex
        @sha256.unpack1("H*")
      end

      def registry_attributes
        { id: @id, zstd_dict_id: @zstd_id, sha256: @sha256, bytes: @bytes }
      end

      private

      def normalize_id(value)
        raise TypeError, "MCDB2 dictionary id must be an Integer" unless value.respond_to?(:to_int)

        integer = value.to_int
        unless integer.between?(1, MAX_DICTIONARY_REF)
          raise ArgumentError, "MCDB2 dictionary id must be in 1..#{MAX_DICTIONARY_REF}"
        end
        integer
      end
    end

    module_function

    # Without a dictionary this emits MCDB1. With Database::Dictionary it emits
    # MCDB2. Choose one format per database column; mixed use is deliberately
    # not what the generated dictionary view is optimized for.
    def compress(text, dictionary: nil)
      return compress_v1(text) if dictionary.nil?

      compress_v2(text, dictionary: dictionary)
    end

    def compress_v1(text)
      bytes = input_bytes!(text, format: "v1")
      frame = MultiCompress.compress(bytes, algo: :zstd, level: ZSTD_LEVEL)
      validate_canonical_zstd_frame!(frame, bytes.bytesize, expected_dictionary_id: 0)
      envelope = header_v1(bytes.bytesize, MultiCompress.crc32(bytes)) << frame
      check_envelope_size!(envelope, MAX_ENVELOPE_V1, "v1")
      envelope
    end

    def compress_v2(text, dictionary:)
      dictionary = database_dictionary!(dictionary)
      bytes = input_bytes!(text, format: "v2")
      frame = MultiCompress.compress(bytes, algo: :zstd, level: ZSTD_LEVEL, dictionary: dictionary.native)
      validate_canonical_zstd_frame!(frame, bytes.bytesize, expected_dictionary_id: dictionary.zstd_id)
      envelope = header_v2(bytes.bytesize, MultiCompress.crc32(bytes), dictionary.id) << frame
      check_envelope_size!(envelope, MAX_ENVELOPE_V2, "v2")
      envelope
    end

    def decompress(blob, dictionary: nil)
      header = parse_header!(blob)
      case header.fetch(:version)
      when VERSION_V1
        raise ArgumentError, "MCDB1 does not accept a dictionary" unless dictionary.nil?

        decode_v1(blob.b, header)
      when VERSION_V2
        decode_v2(blob.b, header, dictionary)
      else
        err("unsupported version #{header.fetch(:version)}")
      end
    end

    def valid?(blob, dictionary: nil)
      decompress(blob, dictionary: dictionary)
      true
    rescue StandardError
      false
    end

    # Parses only the envelope header. It is safe for registry/FK consistency
    # checks and does not decompress the payload.
    def dictionary_ref(blob)
      header = parse_header!(blob)
      return nil if header.fetch(:version) == VERSION_V1

      header.fetch(:dictionary_ref)
    end

    def original_size(blob)
      parse_header!(blob).fetch(:original_size)
    end

    def version_string
      "MCDB1 + MCDB2 (zstd #{MultiCompress.version(:zstd)})"
    end

    def input_bytes!(text, format:)
      raise TypeError, "MultiCompress::Database.compress expects a String, got #{text.class}" unless text.is_a?(String)

      bytes = utf8_bytes(text)
      n = bytes.bytesize
      if n > MAX_OUTPUT
        raise ArgumentError, "MultiCompress::Database: input is #{n} bytes, over the #{MAX_OUTPUT}-byte #{format} limit"
      end
      bytes
    end
    private_class_method :input_bytes!

    def decode_v1(blob, header)
      frame = blob.byteslice(V1_HEADER_SIZE, blob.bytesize - V1_HEADER_SIZE) || +"".b
      validate_canonical_zstd_frame!(frame, header.fetch(:original_size), expected_dictionary_id: 0)
      out = MultiCompress.decompress(frame, algo: :zstd, max_output_size: MAX_OUTPUT)
      validate_decoded!(blob, header, out)
    end
    private_class_method :decode_v1

    def decode_v2(blob, header, dictionary)
      err("MCDB2 requires a dictionary") if dictionary.nil?
      dictionary = database_dictionary!(dictionary)
      if dictionary.id != header.fetch(:dictionary_ref)
        err("dictionary reference #{header.fetch(:dictionary_ref)} does not match supplied dictionary #{dictionary.id}")
      end

      frame = blob.byteslice(V2_HEADER_SIZE, blob.bytesize - V2_HEADER_SIZE) || +"".b
      validate_canonical_zstd_frame!(frame, header.fetch(:original_size), expected_dictionary_id: dictionary.zstd_id)
      out = MultiCompress.decompress(
        frame,
        algo: :zstd,
        dictionary: dictionary.native,
        max_output_size: MAX_OUTPUT
      )
      validate_decoded!(blob, header, out)
    end
    private_class_method :decode_v2

    def parse_header!(blob)
      raise TypeError, "MultiCompress::Database.decompress expects a String, got #{blob.class}" unless blob.is_a?(String)

      b = blob.b
      err("truncated envelope (#{b.bytesize} < #{V1_HEADER_SIZE} bytes)") if b.bytesize < V1_HEADER_SIZE
      err("bad magic") unless b.byteslice(0, 4) == MAGIC

      version = b.getbyte(4)
      case version
      when VERSION_V1
        header_size = V1_HEADER_SIZE
        max_envelope = MAX_ENVELOPE_V1
      when VERSION_V2
        header_size = V2_HEADER_SIZE
        max_envelope = MAX_ENVELOPE_V2
      else
        err("unsupported version #{version}")
      end

      err("truncated #{format_name(version)} envelope (#{b.bytesize} < #{header_size} bytes)") if b.bytesize < header_size
      err("stored #{format_name(version)} envelope is #{b.bytesize} bytes, over the #{max_envelope}-byte limit") if b.bytesize > max_envelope
      err("unsupported codec #{b.getbyte(5)}") unless b.getbyte(5) == CODEC_ZSTD
      err("reserved flags must be 0, got #{b.getbyte(6)}") unless b.getbyte(6) == FLAGS_NONE

      original_size = b.byteslice(ORIGINAL_SIZE_OFFSET, 8).unpack1("Q<")
      err("declared size #{original_size} over the #{MAX_OUTPUT}-byte limit") if original_size > MAX_OUTPUT

      header = {
        version: version,
        header_size: header_size,
        original_size: original_size,
        expected_crc: b.byteslice(CRC_OFFSET, 4).unpack1("L<")
      }
      if version == VERSION_V2
        dictionary_ref = b.byteslice(DICTIONARY_REF_OFFSET, 8).unpack1("Q<")
        unless dictionary_ref.between?(1, MAX_DICTIONARY_REF)
          err("invalid dictionary reference #{dictionary_ref}")
        end
        header[:dictionary_ref] = dictionary_ref
      end
      header
    end
    private_class_method :parse_header!

    def validate_decoded!(blob, header, out)
      if out.bytesize != header.fetch(:original_size)
        err("size mismatch: header says #{header.fetch(:original_size)}, got #{out.bytesize}")
      end
      actual_crc = MultiCompress.crc32(out)
      if actual_crc != header.fetch(:expected_crc)
        err("crc32 mismatch: header #{header.fetch(:expected_crc)}, computed #{actual_crc}")
      end
      s = out.force_encoding(Encoding::UTF_8)
      err("decompressed bytes are not valid UTF-8") unless s.valid_encoding?
      err("decompressed text contains a NUL byte") if s.include?("\0")
      s
    end
    private_class_method :validate_decoded!

    def utf8_bytes(text)
      s = text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "MultiCompress::Database: input is not valid UTF-8" unless s.valid_encoding?
      raise ArgumentError, "MultiCompress::Database: input contains a NUL byte" if s.include?("\0")

      s.b
    end
    private_class_method :utf8_bytes

    def validate_canonical_zstd_frame!(frame, expected_size, expected_dictionary_id:)
      _frame_size, content_size = MultiCompress.zstd_single_frame_info(frame)
      err("zstd frame content size #{content_size} does not match header size #{expected_size}") if content_size != expected_size
      actual_dictionary_id = MultiCompress.zstd_frame_dictionary_id(frame)
      if actual_dictionary_id != expected_dictionary_id
        err("zstd frame dictionary id #{actual_dictionary_id} does not match expected #{expected_dictionary_id}")
      end
    rescue MultiCompress::DataError => e
      err(e.message.sub(/\AMultiCompress::Database: /, ""))
    end
    private_class_method :validate_canonical_zstd_frame!

    def database_dictionary!(value)
      return value if value.is_a?(Dictionary)

      raise TypeError, "MCDB2 requires MultiCompress::Database::Dictionary, got #{value.class}"
    end
    private_class_method :database_dictionary!

    def check_envelope_size!(envelope, max, format)
      return if envelope.bytesize <= max

      raise MultiCompress::DataError,
            "MultiCompress::Database: stored #{format} envelope is #{envelope.bytesize} bytes, over the #{max}-byte limit"
    end
    private_class_method :check_envelope_size!

    def header_v1(original_size, crc32)
      (MAGIC + [VERSION_V1, CODEC_ZSTD, FLAGS_NONE].pack("C3") +
        [original_size].pack("Q<") + [crc32].pack("L<")).b
    end
    private_class_method :header_v1

    def header_v2(original_size, crc32, dictionary_ref)
      (MAGIC + [VERSION_V2, CODEC_ZSTD, FLAGS_NONE].pack("C3") +
        [original_size].pack("Q<") + [crc32].pack("L<") + [dictionary_ref].pack("Q<")).b
    end
    private_class_method :header_v2

    def format_name(version)
      version == VERSION_V2 ? "MCDB2" : "MCDB1"
    end
    private_class_method :format_name

    def err(message)
      raise MultiCompress::DataError, "MultiCompress::Database: #{message}"
    end
    private_class_method :err
  end
end
