# frozen_string_literal: true

module MultiCompress
  module Database
    class Engine
      private

      def decode_v1(blob, header)
        frame = blob.byteslice(V1_HEADER_SIZE, blob.bytesize - V1_HEADER_SIZE) || +"".b
        validate_canonical_zstd_frame!(frame, header.fetch(:original_size), expected_dictionary_id: 0)
        out = MultiCompress.decompress(frame, algo: :zstd, max_output_size: MAX_OUTPUT)
        validate_decoded!(blob, header, out)
      end

      def decode_v2(blob, header, dictionary)
        dictionary = match_dictionary!(dictionary, header)
        frame = blob.byteslice(V2_HEADER_SIZE, blob.bytesize - V2_HEADER_SIZE) || +"".b
        validate_canonical_zstd_frame!(frame, header.fetch(:original_size), expected_dictionary_id: dictionary.zstd_id)
        out = decompress_dictionary_frame(frame, dictionary)
        validate_decoded!(blob, header, out)
      end

      def match_dictionary!(dictionary, header)
        err("MCDB2 requires a dictionary") if dictionary.nil?
        dictionary = database_dictionary!(dictionary)
        expected_ref = header.fetch(:dictionary_ref)
        return dictionary if dictionary.id == expected_ref

        err("dictionary reference #{expected_ref} does not match supplied dictionary #{dictionary.id}")
      end

      def decompress_dictionary_frame(frame, dictionary)
        MultiCompress.decompress(
          frame,
          algo: :zstd,
          dictionary: dictionary.native,
          max_output_size: MAX_OUTPUT
        )
      end
    end
  end
end
