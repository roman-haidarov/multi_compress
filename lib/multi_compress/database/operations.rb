# frozen_string_literal: true

module MultiCompress
  module Database
    class Engine
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
    end
  end
end
