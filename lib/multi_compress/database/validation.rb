# frozen_string_literal: true

module MultiCompress
  module Database
    class Engine
      private

      def validate_decoded!(_blob, header, out)
        validate_decoded_size!(header, out)
        validate_decoded_crc!(header, out)
        validate_decoded_text(out)
      end

      def validate_decoded_size!(header, out)
        expected_size = header.fetch(:original_size)
        return if out.bytesize == expected_size

        err("size mismatch: header says #{expected_size}, got #{out.bytesize}")
      end

      def validate_decoded_crc!(header, out)
        expected_crc = header.fetch(:expected_crc)
        actual_crc = MultiCompress.crc32(out)
        return if actual_crc == expected_crc

        err("crc32 mismatch: header #{expected_crc}, computed #{actual_crc}")
      end

      def validate_decoded_text(out)
        text = out.force_encoding(Encoding::UTF_8)
        err("decompressed bytes are not valid UTF-8") unless text.valid_encoding?
        err("decompressed text contains a NUL byte") if text.include?("\0")
        text
      end

      def utf8_bytes(text)
        s = text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8)
        raise ArgumentError, "MultiCompress::Database: input is not valid UTF-8" unless s.valid_encoding?
        raise ArgumentError, "MultiCompress::Database: input contains a NUL byte" if s.include?("\0")

        s.b
      end

      def validate_canonical_zstd_frame!(frame, expected_size, expected_dictionary_id:)
        _frame_size, content_size = MultiCompress.zstd_single_frame_info(frame)
        if content_size != expected_size
          err("zstd frame content size #{content_size} does not match header size #{expected_size}")
        end
        actual_dictionary_id = MultiCompress.zstd_frame_dictionary_id(frame)
        if actual_dictionary_id != expected_dictionary_id
          err("zstd frame dictionary id #{actual_dictionary_id} does not match expected #{expected_dictionary_id}")
        end
      rescue MultiCompress::DataError => e
        err(e.message.sub(/\AMultiCompress::Database: /, ""))
      end

      def database_dictionary!(value)
        return value if value.is_a?(Dictionary)

        raise TypeError, "MCDB2 requires MultiCompress::Database::Dictionary, got #{value.class}"
      end

      def check_envelope_size!(envelope, max, format)
        return if envelope.bytesize <= max

        raise MultiCompress::DataError,
              "MultiCompress::Database: stored #{format} envelope is #{envelope.bytesize} bytes, " \
              "over the #{max}-byte limit"
      end

      def header_v1(original_size, crc32)
        encode_header(VERSION_V1, original_size, crc32)
      end

      def header_v2(original_size, crc32, dictionary_ref)
        encode_header(VERSION_V2, original_size, crc32, dictionary_ref)
      end

      def encode_header(version, original_size, crc32, dictionary_ref = nil)
        header = MAGIC + [version, CODEC_ZSTD, FLAGS_NONE].pack("C3") +
                 [original_size].pack("Q<") + [crc32].pack("L<")
        header << [dictionary_ref].pack("Q<") unless dictionary_ref.nil?
        header.b
      end

      def format_name(version)
        version == VERSION_V2 ? "MCDB2" : "MCDB1"
      end

      def err(message)
        raise MultiCompress::DataError, "MultiCompress::Database: #{message}"
      end
    end
  end
end
