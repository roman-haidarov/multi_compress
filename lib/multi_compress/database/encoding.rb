# frozen_string_literal: true

module MultiCompress
  module Database
    class Engine
      private

      def input_bytes!(text, format:)
        validate_input_type!(text)

        bytes = utf8_bytes(text)
        validate_input_size!(bytes, format)
        bytes
      end

      def validate_input_type!(text)
        return if text.is_a?(String)

        raise TypeError, "MultiCompress::Database.compress expects a String, got #{text.class}"
      end

      def validate_input_size!(bytes, format)
        size = bytes.bytesize
        return unless size > MAX_OUTPUT

        raise ArgumentError,
              "MultiCompress::Database: input is #{size} bytes, over the #{MAX_OUTPUT}-byte #{format} limit"
      end
    end
  end
end
