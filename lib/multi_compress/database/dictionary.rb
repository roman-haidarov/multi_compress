# frozen_string_literal: true

module MultiCompress
  module Database
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
        @native = build_native(native, bytes)
        @bytes = validate_bytes(@native.bytes.b.freeze)
        @zstd_id = validate_zstd_id(@native.zstd_id)
        @sha256 = Digest::SHA256.digest(@bytes).freeze
        freeze
      end

      def sha256_hex
        sha256.unpack1("H*")
      end

      def registry_attributes
        { id: id, zstd_dict_id: zstd_id, sha256: sha256, bytes: bytes }
      end

      private

      def build_native(native, bytes)
        raise ArgumentError, "provide exactly one of native: or bytes:" if (!!native) == (!!bytes)

        value = native || MultiCompress::Dictionary.new(bytes, algo: :zstd)
        return value if value.is_a?(MultiCompress::Dictionary) && value.algo == :zstd

        raise TypeError, "MCDB2 dictionary must be a MultiCompress::Dictionary with algo: :zstd"
      end

      def validate_bytes(value)
        return value unless value.empty? || value.bytesize > MAX_DICTIONARY_BYTES

        raise ArgumentError,
              "MCDB2 dictionary is #{value.bytesize} bytes; allowed range is 1..#{MAX_DICTIONARY_BYTES}"
      end

      def validate_zstd_id(value)
        return value unless value.zero?

        raise ArgumentError, "MCDB2 dictionary must be a conformant zstd dictionary with a non-zero DictID"
      end

      def normalize_id(value)
        raise TypeError, "MCDB2 dictionary id must be an Integer" unless value.respond_to?(:to_int)

        integer = value.to_int
        unless integer.between?(1, MAX_DICTIONARY_REF)
          raise ArgumentError, "MCDB2 dictionary id must be in 1..#{MAX_DICTIONARY_REF}"
        end

        integer
      end
    end
  end
end
