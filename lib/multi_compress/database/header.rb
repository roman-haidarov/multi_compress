# frozen_string_literal: true

module MultiCompress
  module Database
    class Engine
      private

      def parse_header!(blob)
        bytes = header_bytes!(blob)
        version = bytes.getbyte(4)
        validate_header_size!(bytes, version)
        header_metadata(bytes, version)
      end

      def header_bytes!(blob)
        unless blob.is_a?(String)
          raise TypeError, "MultiCompress::Database.decompress expects a String, got #{blob.class}"
        end

        bytes = blob.b
        err("truncated envelope (#{bytes.bytesize} < #{V1_HEADER_SIZE} bytes)") if bytes.bytesize < V1_HEADER_SIZE
        err("bad magic") unless bytes.byteslice(0, 4) == MAGIC
        bytes
      end

      def validate_header_size!(bytes, version)
        header_size, max_envelope = envelope_limits(version)
        if bytes.bytesize < header_size
          err("truncated #{format_name(version)} envelope (#{bytes.bytesize} < #{header_size} bytes)")
        end
        if bytes.bytesize > max_envelope
          err("stored #{format_name(version)} envelope is #{bytes.bytesize} bytes, over the #{max_envelope}-byte limit")
        end
        validate_fixed_header!(bytes)
      end

      def envelope_limits(version)
        case version
        when VERSION_V1 then [V1_HEADER_SIZE, MAX_ENVELOPE_V1]
        when VERSION_V2 then [V2_HEADER_SIZE, MAX_ENVELOPE_V2]
        else err("unsupported version #{version}")
        end
      end

      def validate_fixed_header!(bytes)
        err("unsupported codec #{bytes.getbyte(5)}") unless bytes.getbyte(5) == CODEC_ZSTD
        err("reserved flags must be 0, got #{bytes.getbyte(6)}") unless bytes.getbyte(6) == FLAGS_NONE

        original_size = bytes.byteslice(ORIGINAL_SIZE_OFFSET, 8).unpack1("Q<")
        err("declared size #{original_size} over the #{MAX_OUTPUT}-byte limit") if original_size > MAX_OUTPUT
      end

      def header_metadata(bytes, version)
        header = {
          version: version,
          header_size: version == VERSION_V2 ? V2_HEADER_SIZE : V1_HEADER_SIZE,
          original_size: bytes.byteslice(ORIGINAL_SIZE_OFFSET, 8).unpack1("Q<"),
          expected_crc: bytes.byteslice(CRC_OFFSET, 4).unpack1("L<")
        }
        header[:dictionary_ref] = dictionary_ref_from_header(bytes) if version == VERSION_V2
        header
      end

      def dictionary_ref_from_header(bytes)
        dictionary_ref = bytes.byteslice(DICTIONARY_REF_OFFSET, 8).unpack1("Q<")
        err("invalid dictionary reference #{dictionary_ref}") unless dictionary_ref.between?(1, MAX_DICTIONARY_REF)
        dictionary_ref
      end
    end
  end
end
